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
# 部署版本标记（APP_REV）
#
# 用途：Render 的 /api/status.version 恒为镜像标签（如 v1.0.0-rc.37），没有区分度，
# 导致"这次 push 到底上线了没有"只能靠 start_time 时间相关性去猜。改这个标记并让
# pool_router 在 /healthz 里回显它，就能对 start.sh 这类非 pool_router 改动做**直接**
# 验证：curl /healthz 看 rev 是否等于本次提交写入的值即可。
#
# 改这里时记得同步 git commit，否则标记会骗人。
# ============================================================================
APP_REV="2026-09-15-auth-secret"
export APP_REV

# 容器启动时刻（unix 秒）。与 new-api 自己的 /api/status.start_time 对比即可判断重启性质：
#   两者接近（几秒内）  -> 整个容器重启（Render 冷启 / 重新部署）
#   start_time 明显更晚 -> 只是 new-api 进程被看门狗重启（崩溃 / 卡连库）
BOOT_TS="$(date -u +%s)"
export BOOT_TS

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

# ============================================================================
# 登录会话上限（修 "活跃登录会话数已达上限"）
#
# 现象：登录被拒，提示"活跃登录会话数已达上限，请在已登录设备上撤销其他会话…"。
#
# 源码定案（common/init.go:142 + service/auth_session.go:79）：
#   common.UserSessionActiveLimit 直接取自 env，默认 50（common/constants.go:41）；
#   登录时判定 activeCount >= UserSessionActiveLimit 即拒绝。
#   全仓不存在"按 SQL 连接池大小钳制会话上限"的逻辑 —— 与上面的连接池加固无关。
#
# 真实原因：本实例 Session 持久化在 Neon Postgres，会跨重启/休眠累积；单账号在多设备、
#   隐身窗口反复登录，day 级累积就撞到 50。
#
# 处置：
#   1) 把上限提到 200 —— 单账号自用足够宽松（每行 session 很小，200 行对 Neon 无压力）。
#   2) 若某次仍撞上限，逃生通道仍是"重置密码"（撤销所有会话）。
#   3) 长期闲置会话由本脚本的 prune_sessions.py 定期清理（见下方"闲置会话清理"段）。
# ============================================================================
export USER_SESSION_ACTIVE_LIMIT="${USER_SESSION_ACTIVE_LIMIT:-200}"
echo "[start.sh] session: ACTIVE_LIMIT=$USER_SESSION_ACTIVE_LIMIT"

# ============================================================================
# 认证密钥稳定性（修 "会话已过期！" / 频繁被要求重新登录）
#
# 现象：网页后台隔一段时间就弹"会话已过期！"并跳回登录页；API Key 调用完全不受影响。
#
# 源码定案（上游 main 分支，逐行读过）：
#   common/constants.go:35   var SessionSecret = uuid.New().String()
#   common/init.go:50        仅当 SESSION_SECRET 环境变量存在时才覆盖它
#   service/auth_token.go:55 authSigningKey() 以 SessionSecret 为 HMAC 密钥，
#                            用于签发/校验 access token（HS256 JWT，TTL 15 分钟）
#   service/auth_session.go:430 hashRefreshSecret() 同样派生自 SessionSecret，
#                            其输出**存进 user_sessions 表**作为刷新令牌的校验值
#   web/src/lib/http-client.ts:117  刷新失败 -> Toast "Session expired!" -> 跳登录页
#
# 结论：不设 SESSION_SECRET 时，它是**每次进程启动随机生成**的 UUID。于是每次 new-api
#   重启（Render 免费层冷启 / 重新部署 / 进程崩溃被看门狗重启），旧 access token 验签
#   失败、refresh token 的哈希也匹配不上库里的记录 -> 刷新失败 -> 被迫重新登录。
#   免费层只要电脑休眠超过 15 分钟就会被回收，所以感觉"没一会儿就要重登"。
#
# 处置：提供一个**跨重启、跨部署都稳定**的 SESSION_SECRET。
#   优先级：Render 环境变量面板的 SESSION_SECRET > 本段派生的稳定值。
#   派生方式：sha256(SQL_DSN)。SQL_DSN 本身就是密钥、且长期不变，因此既不把明文密钥
#   写进仓库（仓库若公开也不至于被人伪造后台令牌），又能保证每次启动得到同一个值。
#   若连 SQL_DSN 都没有，则只告警、不设置，保持上游行为（避免引入一个可从仓库推出的弱密钥）。
#
# 注意：切换密钥这一次会让**当前已登录的会话失效一次**，重新登录即可；此后不再频繁掉线。
# ============================================================================
AUTH_SECRET_SOURCE="none"
if [ -n "$SESSION_SECRET" ]; then
  AUTH_SECRET_SOURCE="env"
  echo "[start.sh] SESSION_SECRET from env (stable)"
elif [ -n "$SQL_DSN" ]; then
  SESSION_SECRET="$(python3 -c 'import hashlib,os;print(hashlib.sha256(("new-api/auth-secret/v1:"+os.environ.get("SQL_DSN","")).encode("utf-8")).hexdigest())')"
  export SESSION_SECRET
  AUTH_SECRET_SOURCE="derived"
  echo "[start.sh] SESSION_SECRET derived from SQL_DSN (stable across restarts)"
else
  echo "[start.sh] WARNING: SESSION_SECRET unset and SQL_DSN missing; web sessions WILL be invalidated on every restart. Set SESSION_SECRET in the Render env panel."
fi
export AUTH_SECRET_SOURCE

# ============================================================================
# 闲置会话清理（默认关闭；需要时用 SESSION_PRUNE_ENABLED=1 打开）
#
# 背景：上游自带清理（service/auth_cleanup.go）每小时跑一次，但只删
#   `expires_at < now` 的**已过期**会话；而 LoginSessionTTL = 30 天
#   （service/auth_token.go:22），所以"登录过但长期没用"的会话会一直占 active 名额。
#   本脚本原本用来补这个缺口：删 last_active_at 早于 N 天的活跃会话。
#
# 2026-09-14 改为**默认关闭**，原因（用户反馈"频繁被要求重新登录"）：
#   1) 它是这套部署里**唯一会用 DELETE 动数据库**的组件，风险与收益不成比例。
#   2) 上游 last_active_at 的语义比想象的弱：它只在**建会话时**
#      （model/user_session.go:155）和**refresh-token 轮换时**（同文件 ~488 行）
#      写入。若某会话长期只用 API、浏览器不做 token 轮换，该字段会长期停在旧值，
#      于是"其实还活着"的会话会被判成闲置 → 误删 → 强制重新登录。
#   3) 冗余：会话上限已提到 200（见上），单账号自用完全够，本不需要自动回收。
#   4) 位置不对：它在**每次容器启动**都跑一次，而免费层每次冷启（PC 休眠后回来）
#      都会触发容器重启 → 潜在误删被放大成"每次回来都要重新登录"。
#
# 打开方式：在 Render 环境变量面板设 SESSION_PRUNE_ENABLED=1（或在下面改默认值）。
#   若打开，prune_sessions.py 现在还会跳过 last_active_at <= 0 的"时间戳未知"行。
# ============================================================================
SESSION_PRUNE_ENABLED="${SESSION_PRUNE_ENABLED:-0}"
SESSION_IDLE_DAYS="${SESSION_IDLE_DAYS:-14}"
SESSION_PRUNE_INTERVAL="${SESSION_PRUNE_INTERVAL:-86400}"
export SESSION_PRUNE_ENABLED
echo "[start.sh] session prune: ENABLED=$SESSION_PRUNE_ENABLED IDLE_DAYS=$SESSION_IDLE_DAYS INTERVAL=${SESSION_PRUNE_INTERVAL}s"

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

# 闲置会话清理循环（默认不跑；详见上方"闲置会话清理"段）
#
# 注意：Render 免费层会休眠，进程重启后计时器归零。若只写 "sleep 24h 再跑"，
# 在频繁休眠的实例上可能**永远跑不到**。因此这里改为：先等 New API 就绪，
# 立刻执行一次（让部署后几分钟内就能在日志里看到结果），再进入周期循环。
if [ "$SESSION_PRUNE_ENABLED" = "1" ]; then
  (
    mkdir -p /data/logs
    # 等 New API 监听 3000（最多 120s），确保它的表结构已就绪
    j=0
    while [ $j -lt 120 ]; do
      python3 -c "import socket; socket.create_connection(('127.0.0.1', 3000), 1)" 2>/dev/null && break
      sleep 2
      j=$((j + 2))
    done
    echo "[start.sh] running initial session prune at $(date)"
    python3 /pool/prune_sessions.py >> /data/logs/session_prune.log 2>&1 \
      || echo "[start.sh] initial prune failed (see /data/logs/session_prune.log)"
    while true; do
      sleep "$SESSION_PRUNE_INTERVAL"
      echo "[start.sh] pruning idle sessions at $(date)"
      python3 /pool/prune_sessions.py >> /data/logs/session_prune.log 2>&1 \
        || echo "[start.sh] prune failed (see /data/logs/session_prune.log)"
    done
  ) &
else
  echo "[start.sh] session prune disabled (SESSION_PRUNE_ENABLED=$SESSION_PRUNE_ENABLED), skipping"
fi

# 给 New API 启动时间（免费层 + Neon 冷启都慢）
sleep 8

cd /pool
exec python3 -m uvicorn pool_router:app --host 0.0.0.0 --port "${PORT:-4000}"
