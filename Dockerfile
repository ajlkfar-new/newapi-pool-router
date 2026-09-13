# 在官方 New API 镜像基础上，合并一个轻量"模型池路由"层。
# 同一个 Render 服务：New API 跑在 3000(内部)，池路由跑在 $PORT(对外)。
FROM calciumion/new-api:latest

USER root

# 装 Python + 路由层依赖（不再需要 supervisor）
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /pool
COPY requirements.txt /pool/requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r /pool/requirements.txt

COPY pool_router.py /pool/pool_router.py
COPY pools.json /pool/pools.json
COPY prune_sessions.py /pool/prune_sessions.py
COPY start.sh /pool/start.sh
RUN chmod +x /pool/start.sh

# 清掉基础镜像自带的 ENTRYPOINT（/new-api），改由 start.sh 统一编排
ENTRYPOINT []
EXPOSE 3000
CMD ["/pool/start.sh"]
