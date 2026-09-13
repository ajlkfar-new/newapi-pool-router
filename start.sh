#!/bin/sh
# 启动脚本：在同一个容器里拉起 New API 与池路由层。
#
# 端口分配：
#   - New API 锁死在 3000，仅供容器内池路由层内部调用。
#   - 池路由层作为前台主进程，监听 Render 注入的 $PORT（外部流量入口），保底 4000。
#
# 关键修复（针对 Neon 免费库休眠）：
#   Neon 免费层会休眠，new-api 启动时若 Neon 尚未唤醒，连库会失败/挂起，进而导致
#   整个后台不可用。这里在启动 new-api 前先用 TCP 探针连一下数据库主机:端口，
#   既「叫醒」Neon，也确认可达，再启动 new-api。
#
# 守护：用 while 循环，new-api 崩溃即 3s 后拉起；日志直接输出到 stdout，
#       以便 Render 日志面板可见（便于排查）。

cd /data

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
    if [ -n "$DB_HOST" ]; then
      n=0
      while [ $n -lt 20 ]; do
        if python3 -c "import socket; socket.create_connection(('$DB_HOST', $DB_PORT), 3)" 2>/dev/null; then
          echo "[start.sh] DB $DB_HOST:$DB_PORT reachable"
          break
        fi
        echo "[start.sh] waiting for DB $DB_HOST:$DB_PORT (try $n)..."
        sleep 3
        n=$((n + 1))
      done
    fi
    echo "[start.sh] launching new-api on :3000 at $(date)"
    PORT=3000 /new-api
    echo "[start.sh] new-api exited ($?) at $(date), restart in 3s"
    sleep 3
  done
) &

# 给 New API 一点启动时间（免费层 + Neon 冷启都慢）
sleep 8

cd /pool
exec python3 -m uvicorn pool_router:app --host 0.0.0.0 --port "${PORT:-4000}"
