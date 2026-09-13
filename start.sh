#!/bin/sh
# 启动脚本：在同一个容器里先后拉起 New API 与池路由层。
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

set -e

# 1) 启动 New API（内部 3000）
cd /data
PORT=3000 /new-api &
NEW_API_PID=$!

# 2) 给 New API 一点启动时间（免费层磁盘/冷启都慢，多等几秒更稳）
sleep 5

# 3) 池路由层作为前台主进程（Render 健康检查打这个端口）
cd /pool
exec python3 -m uvicorn pool_router:app --host 0.0.0.0 --port "${PORT:-4000}"
