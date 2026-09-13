"""
轻量 LLM 模型池路由层 (FastAPI)。

职责：
  1. 客户端只需配置一个池别名(如 free)，本层按 pools.json 的顺序，
     把请求转发给 New API(内部 3000) 上对应的真实模型名；前一个失败自动换下一个。
  2. /v1/models 只返回池别名 -> 客户端下拉里不再出现一长串模型。
  3. 其余路径(后台 UI、/api/* 等)原样反向代理到 New API，后台管理照常可用。

环境变量：
  NEW_API_BASE    New API 内部地址，默认 http://localhost:3000
  NEW_API_TOKEN   调 New API 时使用的令牌(在 New API 后台创建，模型限制放开到池里所有真实名)
  POOL_CONFIG     pools.json 路径，默认 /pool/pools.json
  PORT            Render 注入的对外端口，默认 4000
"""
import os
import json
import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse

NEW_API_BASE = os.environ.get("NEW_API_BASE", "http://localhost:3000").rstrip("/")
NEW_API_TOKEN = os.environ.get("NEW_API_TOKEN", "")
POOL_CONFIG_PATH = os.environ.get("POOL_CONFIG", "/pool/pools.json")

app = FastAPI()

# 需要剥离的逐跳/长度相关头，避免转发后长度不匹配
HOP_HEADERS = {
    "transfer-encoding",
    "content-length",
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "upgrade",
    "host",
}


def load_pools():
    try:
        with open(POOL_CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


POOLS = load_pools()


def _new_client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        timeout=httpx.Timeout(300.0, connect=15.0),
        follow_redirects=False,
    )


async def _open_stream(client: httpx.AsyncClient, method: str, url: str, **kw):
    """正确地以流式方式发起上游请求。

    注意：httpx 的 client.stream() 返回的是异步上下文管理器，不能被 await。
    这里用 build_request + send(stream=True)，两者都是可 await 的。
    """
    req = client.build_request(method, url, **kw)
    return await client.send(req, stream=True)


def _strip_hop_headers(headers):
    return {k: v for k, v in headers.items() if k.lower() not in HOP_HEADERS}


@app.get("/healthz")
async def health():
    return {"status": "ok"}


@app.get("/v1/models")
async def list_models():
    data = [
        {
            "id": name,
            "object": "model",
            "owned_by": "pool-router",
            "created": 0,
            "permission": [],
            "root": name,
        }
        for name in POOLS.keys()
        if not name.startswith("_")
    ]
    return {"object": "list", "data": data}


@app.api_route("/v1/chat/completions", methods=["POST"])
async def chat_completions(request: Request):
    raw = await request.body()
    try:
        payload = json.loads(raw)
    except Exception:
        return Response(
            content=json.dumps({"error": {"message": "invalid JSON"}}).encode(),
            status_code=400,
            media_type="application/json",
        )

    model = payload.get("model", "")
    pool = POOLS.get(model)
    candidates = pool if isinstance(pool, list) and pool else [model]
    stream = bool(payload.get("stream", False))
    last_err = None

    for cand in candidates:
        attempt = dict(payload)
        attempt["model"] = cand
        headers = {
            "Authorization": f"Bearer {NEW_API_TOKEN}",
            "Content-Type": "application/json",
        }
        client = _new_client()
        try:
            if stream:
                upstream = await _open_stream(
                    client,
                    "POST",
                    f"{NEW_API_BASE}/v1/chat/completions",
                    json=attempt,
                    headers=headers,
                )
                if upstream.status_code != 200:
                    err = await upstream.aread()
                    await upstream.aclose()
                    await client.aclose()
                    last_err = (upstream.status_code, err)
                    continue

                async def gen(client=client, upstream=upstream):
                    try:
                        async for chunk in upstream.aiter_raw():
                            yield chunk
                    finally:
                        await upstream.aclose()
                        await client.aclose()

                return StreamingResponse(
                    gen(),
                    media_type="text/event-stream",
                    headers={
                        "Cache-Control": "no-cache",
                        "Connection": "keep-alive",
                        "X-Accel-Buffering": "no",
                    },
                )

            resp = await client.post(
                f"{NEW_API_BASE}/v1/chat/completions",
                json=attempt,
                headers=headers,
            )
            if resp.status_code != 200:
                last_err = (resp.status_code, resp.content)
                await client.aclose()
                continue
            content = resp.content
            resp_headers = _strip_hop_headers(resp.headers)
            await client.aclose()
            return Response(
                content=content,
                status_code=200,
                media_type=resp.headers.get("content-type", "application/json"),
                headers=resp_headers,
            )
        except Exception as e:
            await client.aclose()
            last_err = (502, json.dumps({"error": {"message": f"upstream error: {e}"}}).encode())
            continue

    code = last_err[0] if last_err else 502
    msg = last_err[1] if last_err else b'{"error":{"message":"all upstream models failed"}}'
    if isinstance(msg, str):
        msg = msg.encode()
    return Response(content=msg, status_code=code, media_type="application/json")


@app.api_route(
    "/{full_path:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"],
)
async def proxy_all(request: Request, full_path: str):
    """把后台 UI、/api/* 等其余请求原样反向代理到 New API(3000)。"""
    target = f"{NEW_API_BASE}/{full_path}"
    headers = {
        k: v
        for k, v in request.headers.items()
        if k.lower() not in HOP_HEADERS
    }
    body = await request.body()
    client = _new_client()
    try:
        upstream = await _open_stream(
            client,
            request.method,
            target,
            params=request.query_params,
            content=body,
            headers=headers,
        )
    except Exception as e:
        await client.aclose()
        return Response(
            content=json.dumps({"error": {"message": f"proxy error: {e}"}}).encode(),
            status_code=502,
            media_type="application/json",
        )

    async def gen(client=client, upstream=upstream):
        try:
            async for chunk in upstream.aiter_raw():
                yield chunk
        finally:
            await upstream.aclose()
            await client.aclose()

    return StreamingResponse(
        gen(),
        status_code=upstream.status_code,
        media_type=upstream.headers.get("content-type"),
        headers=_strip_hop_headers(upstream.headers),
    )


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("PORT", "4000"))
    uvicorn.run(app, host="0.0.0.0", port=port)
