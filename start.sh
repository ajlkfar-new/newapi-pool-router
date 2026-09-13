#!/bin/sh
# 启动脚本：在同一个容器里拉起 New API 与池路由层。
#
# 端口分配（关键，避免冲突）：
#   - New API 锁死在 3000，仅供容器内池路由层内部调用，外部不可直接访问。
#   - 池路由层作为「前台主进程」，监听 Render 注入的 $PORT（外部流量入口），
#     保底 4000（本地没设 $PORT 时，方便本机调试）。
#
# 为什么不用 supervisord 的 environment 去设 PORT：
#   new-api 二进制会读取 PORT 环境变量；supervisord 的 environment 覆盖在
#   某些版本下不可靠，导致 new-api 抢到 Render 的对外端口、池路由层反而没接住。
#   这里用 `PORT=3000 /new-api` 直接给该命令钉死端口，确定性最强。
#
# 为什么用 while 循环守护 new-api：
#   原先把 new-api 当裸后台进程(&)跑，它一旦崩溃（典型：Neon 免费库冷启瞬断、
#   连不上数据库）就永久死亡，而 Render 只健康检查对外 $PORT(uvicorn 一直健康)，
#   不会重启容器，导致后台再也登不上、对话全 502。用 while 循环挂了就拉起，
#   既能扛偶发崩溃，也能在 Neon 唤醒过程中持续重试直到连上。

# 1) 守护 New API（内部 3000，挂了自动重启），日志落盘便于排查
cd /data
(
  while true; do
    echo "[start.sh] launching new-api on :3000 at $(date)"
    PORT=3000 /new-api >> /var/log/new-api.out.log 2>&1
    echo "[start.sh] new-api exited ($?) at $(date), restart in 3s" >> /var/log/new-api.out.log 2>&1
    sleep 3
  done
) &

# 2) 给 New API 一点启动时间（免费层 + Neon 冷启都慢，多等几秒更稳）
sleep 8

# 3) 池路由层作为前台主进程（Render 健康检查打这个端口）
cd /pool
exec python3 -m uvicorn pool_router:app --host 0.0.0.0 --port "${PORT:-4000}"
