# 在官方 New API 镜像基础上，合并一个轻量"模型池路由"层。
# 同一个 Render 服务：New API 跑在 3000(内部)，池路由跑在 4000(对外)。
FROM calciumion/new-api:latest

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip supervisor \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /pool
COPY requirements.txt /pool/requirements.txt
RUN pip3 install --no-cache-dir -r /pool/requirements.txt

COPY pool_router.py /pool/pool_router.py
COPY pools.json /pool/pools.json
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# 对外只暴露池路由端口；New API 的 3000 仅在容器内部可达
EXPOSE 4000

CMD ["supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
