#!/bin/sh
# 启动脚本：在同一个容器里拉起 New API 与池路由层。
#
# 端口分配：
#   - New API 锁死在 3000，仅供容器内池路由层内部调用。
#   - 池路由层作为前台主进程，监听 Render 注入的 $PORT（外部流量入口），保底 4000。
#
# 关键修复（针对 Neon 免费库休眠）：
#   new-api 启动若 Neon 尚未就绪，会卡在连库（进程不退出）。之前的"退出即重启"
#   守护对此无效，导致后台永久 502。这里加看门狗：new-api 启动后若 45s 内未监听
#   3000，强制 kill 重启；重启会重新探针/唤醒 Neon，循环直到它真正起来。
#   （Neon 代理端口永远接受 TCP，所以 TCP 探针只能触发唤醒、不能判断就绪，必须靠
#    实际是否监听 3000 来判断。）
#
# 日志直接输出到 stdout，便于 Render 日志面板排查。

cd /data

# ============================================================================
# 抗闪退加固（用一次模型后偶发退出）
#
# 根因（按可能性排序）：
#   1) 连接池过大：new-api 默认 SQL_MAX_OPEN_CONNS=1000 / IDLE=100，远超 Neon
#      免费层连接上限。一旦写请求日志/扣费（即"用过一次模型"）就会把 Neon 连接
#      打满，导致查询报错、进程异常退出。→ 直接压到 10/5。
#   2) 内存 OOM：Render 免费层 512MB，Go(new-api) + Python(uvicorn) 双进程共享，
#      Go 默认 GC 目标会一路吃掉内存。→ GOMEMLIMIT 给 Go 一个软上限。
#   3) 冷启 502 被误判为"闪退"（Neon/Render 双重休眠，十几秒属正常）。
#
# 写法说明：全部用 ${VAR:-默认值}，即"Render 环境变量面板里设了就以面板为准"，
# 没设才用这里的保守默认值。所以不必去面板改，也能立刻生效；需要调整时再在面板覆盖。
# ============================================================================
export SQL_MAX_OPEN_CONNS="${SQL_MAX_OPEN_CONNS:-10}"
export SQL_MAX_IDLE_CONNS="${SQL_MAX_IDLE_CONNS:-5}"
export SQL_MAX_LIFETIME="${SQL_MAX_LIFETIME:-60}"
export GOMEMLIMIT="${GOMEMLIMIT:-300MiB}"
export ERROR_LOG_ENABLED="${ERROR_LOG_ENABLED:-true}"
echo "[start.sh] hardening: OPEN_CONNS=$SQL_MAX_OPEN_CONNS IDLE=$SQL_MAX_IDLE_CONNS LIFETIME=${SQL_MAX_LIFETIME}s GOMEMLIMIT=$GOMEMLIMIT"

# 从 SQL_DSN 解析数据库主机:端口（Neon 为 postgres://user:pass@host:5432/db）
DB_HOST=""
DB_PORT="5432"
if [ -n "$SQL_DSN" ]; then
  DB_HOST=$(echo "$SQL_DSN" | sed -E 's#.*@([^:/]+)(:[0-9]+)?/.*#\1#')
  P=$(echo "$SQL_DSN" | sed -E 's#.*@[^:/]+:([0-9]+)/.*#\1#')
  [ -n "$P" ] && DB_PORT="$P"
fi

(
  while true; do
    # 先连一下数据库主机:端口，触发 Neon 唤醒（代理端口始终可连，仅用于唤醒）
    if [ -n "$DB_HOST" ]; then
      python3 -c "import socket; socket.create_connection(('$DB_HOST', $DB_PORT), 3)" 2>/dev/null \
        && echo "[start.sh] DB TCP reachable" \
        || echo "[start.sh] DB TCP not yet (triggering wake)"
    fi
    echo "[start.sh] launching new-api on :3000 at $(date)"
    PORT=3000 /new-api &
    NA_PID=$!
    # 看门狗：45s 内若 3000 未监听（卡在连库/冷启），杀掉强制重启
    k=0
    while [ $k -lt 45 ]; do
      if python3 -c "import socket; socket.create_connection(('127.0.0.1', 3000), 1)" 2>/dev/null; then
        echo "[start.sh] new-api up on :3000"
        break
      fi
      sleep 1
      k=$((k + 1))
    done
    if [ $k -ge 45 ]; then
      echo "[start.sh] new-api did not bind :3000 in 45s (likely Neon cold start), killing & retry"
      kill -9 "$NA_PID" 2>/dev/null
    fi
    wait "$NA_PID" 2>/dev/null
    echo "[start.sh] new-api exited, restart in 3s"
    sleep 3
  done
) &

# 给 New API 启动时间（免费层 + Neon 冷启都慢）
sleep 8

cd /pool
exec python3 -m uvicorn pool_router:app --host 0.0.0.0 --port "${PORT:-4000}"
