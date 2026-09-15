"""
轻量 LLM 模型池路由层 (FastAPI)。

职责：
  1. 客户端只需配置一个池别名(如 free)，本层按 pools.json 的顺序，
     把请求转发给 New API(内部 3000) 上对应的真实模型名；前一个失败自动换下一个。
  2. /v1/models 只返回池别名 -> 客户端下拉里不再出现一长串模型。
  3. /healthz 汇报配置是否加载成功 + 池数量 + 配置指纹 + 部署版本标记(APP_REV) +
     会话清理开关状态；/pools 只读回显完整映射(需 Bearer 令牌)。这几个端点用于确认
     "部署是否真的生效、顺序到底是什么、有没有组件在动数据库"。
  4. 其余路径(后台 UI、/api/* 等)原样反向代理到 New API，后台管理照常可用。

环境变量：
  NEW_API_BASE      New API 内部地址，默认 http://localhost:3000
  NEW_API_TOKEN     调 New API 时使用的令牌(在 New API 后台创建，模型限制放开到池里所有真实名)
  POOLS_ADMIN_TOKEN /pools 端点的访问令牌；未设置时回退用 NEW_API_TOKEN；都没设则拒绝访问
  POOL_CONFIG       pools.json 路径，默认 /pool/pools.json
  PORT              Render 注入的对外端口，默认 4000
"""
import os
import json
import hmac
import hashlib
import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse

NEW_API_BASE = os.environ.get("NEW_API_BASE", "http://localhost:3000").rstrip("/")
NEW_API_TOKEN = os.environ.get("NEW_API_TOKEN", "")
POOL_CONFIG_PATH = os.environ.get("POOL_CONFIG", "/pool/pools.json")
POOLS_ADMIN_TOKEN = os.environ.get("POOLS_ADMIN_TOKEN", "")

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
    """读取并校验 pools.json。

    返回 (pools, ok, detail, digest)：
      ok=False 表示配置不可用(文件缺失 / JSON 语法错 / 结构不对)，此时 pools 尽量
      保留能用的条目；detail 是给人看的原因；digest 是配置内容的指纹。

    digest = 对「解析后的 JSON」做 canonical 序列化(键排序、无空格)再 sha256，取前 12 位。
    因为基于解析结果而非原始字节，它不受换行符(CRLF/LF)、缩进、键顺序影响，
    所以可以和本机仓库里的文件算出同一个值 —— 用来确认线上跑的就是仓库那一份，
    连"池内模型顺序"这种从响应里看不出来的变化也能验证。

    设计取舍：这里**不抛异常、不退出进程**。解析失败时宁可"带病启动"并把错误大声
    打出来(日志 + /healthz 的 config_ok)，也不让容器直接崩掉 —— 免费层上崩溃重启
    会白烧 instance hours，且 Render 的降级行为不直观。
    """
    try:
        with open(POOL_CONFIG_PATH, "r", encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return {}, False, f"config not found: {POOL_CONFIG_PATH}", ""
    except Exception as e:
        return {}, False, f"cannot read {POOL_CONFIG_PATH}: {e}", ""

    if not text.strip():
        return {}, False, f"config is empty: {POOL_CONFIG_PATH}", ""

    try:
        data = json.loads(text)
    except Exception as e:
        return {}, False, f"INVALID JSON in {POOL_CONFIG_PATH}: {e}", ""

    if not isinstance(data, dict):
        return {}, False, f"root must be a JSON object, got {type(data).__name__}", ""

    digest = hashlib.sha256(
        json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    ).hexdigest()[:12]

    pools = {}
    problems = []
    for k, v in data.items():
        if k.startswith("_"):
            continue  # 下划线开头 = 注释/元数据，不作为模型暴露
        if not isinstance(v, list) or not v or not all(isinstance(x, str) and x.strip() for x in v):
            problems.append(f"{k!r} must be a non-empty array of non-empty strings")
            continue
        pools[k] = v

    if problems:
        return pools, False, "; ".join(problems), digest
    return pools, True, f"{len(pools)} pools loaded", digest


POOLS, POOLS_OK, POOLS_DETAIL, POOLS_DIGEST = load_pools()

# ---- 启动自检：把"当前到底加载了什么"直接打进容器日志 ----
# 有了这几行，以后改完池子看部署日志即可确认顺序(含顺序)，不必再从外部推断；配置坏了
# 也会在启动瞬间就出现刺眼的 ERROR 行，而不是等到客户端一个池都用不了才发现。
if POOLS_OK:
    print(f"[pool_router] config OK ({POOLS_DETAIL}) sha={POOLS_DIGEST}", flush=True)
else:
    print(f"[pool_router] !!! POOLS CONFIG ERROR: {POOLS_DETAIL}", flush=True)
    print(
        "[pool_router] !!! /v1/models will be EMPTY and every pool alias will FAIL"
        " until pools.json is fixed",
        flush=True,
    )
for _name, _models in POOLS.items():
    print(f"[pool_router]   {_name}: {' -> '.join(_models)}", flush=True)


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


def _pools_authorized(request: Request) -> bool:
    """校验 /pools 的 Bearer 令牌。

    优先 POOLS_ADMIN_TOKEN，未设置则回退 NEW_API_TOKEN；两者都没配时**直接拒绝**
    (fail-safe)——宁可这个端点用不了，也不要把它敞开在公网上。
    """
    expected = POOLS_ADMIN_TOKEN or NEW_API_TOKEN
    if not expected:
        return False
    auth = request.headers.get("authorization", "") or ""
    if not auth.lower().startswith("bearer "):
        return False
    try:
        return hmac.compare_digest(
            auth[7:].strip().encode("utf-8"), expected.encode("utf-8")
        )
    except Exception:
        return False


@app.get("/healthz")
async def health():
    """健康检查：除了存活，还汇报池配置是否加载成功。

    注意 HTTP 状态码恒为 200(即使 config_ok=false)。因为 Render 的 health check
    若用它，返回非 2xx 会触发回滚/重启；而"配置写错了"我们希望你看得见、而不是
    让服务反复重启。判断是否正常请看 config_ok 字段。

    config_sha 是配置指纹：与本机 `pools.json` 用同样算法算出的值比对，即可确认
    线上部署的就是仓库里这一份(含池内顺序)。
    """
    return {
        "status": "ok" if POOLS_OK else "degraded",
        "rev": os.environ.get("APP_REV", ""),
        "config_ok": POOLS_OK,
        "config_detail": POOLS_DETAIL,
        "config_sha": POOLS_DIGEST,
        "pools_count": len(POOLS),
        "pools": list(POOLS.keys()),
        # 会话清理是这套部署里唯一会用 DELETE 动数据的组件，它是否在跑必须可见。
        "session_prune_enabled": os.environ.get("SESSION_PRUNE_ENABLED", "0") == "1",
    }


@app.get("/pools")
async def show_pools(request: Request):
    """只读回显当前**已加载**的池配置(池别名 -> 真实模型名列表)。

    用途：改完 pools.json 后确认部署是否生效、以及每个池的实际顺序 —— 这些都是
    从 /v1/models 和调用响应里看不出来的。需要 Bearer 令牌。
    """
    if not _pools_authorized(request):
        return Response(
            content=json.dumps(
                {
                    "error": {
                        "message": (
                            "unauthorized: set POOLS_ADMIN_TOKEN (or NEW_API_TOKEN) on the "
                            "service and call with 'Authorization: Bearer <token>'"
                        )
                    }
                }
            ).encode(),
            status_code=401,
            media_type="application/json",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return {
        "config_ok": POOLS_OK,
        "config_detail": POOLS_DETAIL,
        "config_sha": POOLS_DIGEST,
        "config_path": POOL_CONFIG_PATH,
        "count": len(POOLS),
        "pools": POOLS,
    }


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
