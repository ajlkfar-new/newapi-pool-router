# 客户端配置清单（模型池路由 · agnes-free）

> 目标：客户端（WorkBuddy / OpenCode 等任意 OpenAI 兼容客户端）**只配 1 条**，
> 就能无感使用 Agnes 的 6 个模型，不用再一个个加。

---

## 0. 先确认你的 Render 服务地址

部署完成后，Render 会给你一个类似这样的地址（在 Render 后台 Web Service 的 **Settings → URL** 里看）：

```
https://newapi-pool-router.onrender.com
```

下文用 `https://你的服务.onrender.com` 代替，请替换成你自己的。

> ⚠️ 免费层 15 分钟无访问会休眠，下次调用自动冷启（约 10~15 秒）。
> 第一次请求可能超时，**重试一次或把客户端超时调大**即可。

---

## 1. 三个必填值（所有客户端通用）

| 字段 | 填什么 | 说明 |
|---|---|---|
| **Base URL** | `https://你的服务.onrender.com/v1` | 注意结尾带 `/v1`；这是路由层（4000 端口）的 OpenAI 兼容入口 |
| **API Key** | `sk-pool`（任意非空字符串） | 路由层**不校验**客户端 Key，它内部用自己的 `NEW_API_TOKEN` 调 New API，所以这里随便填 |
| **Model** | `agnes-free` | 池别名；`/v1/models` 只返回这一个名 |

---

## 2. WorkBuddy 里怎么填

在 WorkBuddy 的「自定义模型 / OpenAI 兼容供应商」里新增一项：

- 名称（自定义）：`Agnes 免费池`
- API 地址：`https://你的服务.onrender.com/v1`
- API Key：`sk-pool`
- 模型名：`agnes-free`

保存后，模型下拉里就只有 `agnes-free` 一个，选中即用。

---

## 3. OpenCode（opencode go）里怎么填

OpenCode 用 OpenAI 兼容 provider 配置。在它的配置文件里加一个 provider，
核心三要素同样是 **baseURL 带 /v1、任意 key、model=agnes-free**。
下面是一份代表写法（具体 key 名请对照你 OpenCode 版本的 schema）：

```jsonc
{
  "provider": {
    "agnes-pool": {
      "name": "agnes-pool",
      "api": {
        "baseURL": "https://你的服务.onrender.com/v1",
        "key": "sk-pool"
      },
      "models": [
        { "id": "agnes-free", "name": "Agnes Free Pool" }
      ]
    }
  }
}
```

> 不同 OpenCode 版本字段名可能略有差异（如 `baseURL` / `base_url`、`key` / `apiKey`）。
> 只要保证「地址带 /v1 + 任意 key + model 写 `agnes-free`」这三点，其余按你版本填即可。
> 这样你就不用再为 OpenCode Go 套餐里的几十个模型逐个加配置了——以后加新模型只改 `pools.json`。

---

## 4. 自测：部署后先验证再上客户端

在终端跑两条命令（替换成你的地址）：

```bash
# 1) 看模型列表——应该只返回 agnes-free
curl https://你的服务.onrender.com/v1/models

# 2) 发一条真实对话，确认能打通并自动路由
curl https://你的服务.onrender.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-pool" \
  -d '{
    "model": "agnes-free",
    "messages": [{"role": "user", "content": "用一句话介绍你自己"}],
    "stream": false
  }'
```

- 第 1 条返回里 `data` 只有 `agnes-free` → 列表清爽 ✅
- 第 2 条能正常返回内容 → 路由 + New API 令牌权限都通了 ✅

---

## 5. 常见问题排查

| 现象 | 原因 | 解决 |
|---|---|---|
| 客户端下拉出现一长串模型 | 客户端没走路由层，直接连了 New API | 确认 Base URL 是 **路由层地址（带 /v1）**，不是 New API 直连地址 |
| 报 `model not found` / `model agnes-free not found` | `pools.json` 没生效或服务没重建 | 去 Render 看构建日志；确认 push 后已成功部署 |
| 报 401 / 无权限 | `NEW_API_TOKEN` 这个 New API 令牌**没放开**那 6 个真实模型名 | 进 New API 后台「令牌」→ 编辑该令牌 → 模型限制填 6 个名或 `*` |
| 返回全是错误 / 无内容 | 6 个 Agnes 真实名在 New API 里不存在 | 确认 New API 渠道里配过 `agnes-2.5-pro` 等（或模型重定向过） |
| 首次请求很慢 / 超时 | 免费层冷启 | 重试一次，或把客户端超时设到 30s+ |

---

## 6. 以后想加模型 / 加新池，只改 `pools.json`

例子：再加一个 `ocg-free` 池（OpenCode Go 的免费模型），或把某个更稳的模型排到 `agnes-free` 前面：

```json
{
  "agnes-free": [
    "agnes-2.5-pro",
    "agnes-2.5-flash",
    "agnes-2.5-pro-alpha",
    "agnes-2.5-pro-beta",
    "agnes-3.0-flash",
    "agnes-2.0-flash"
  ],
  "ocg-free": [
    "ocg-model-a",
    "ocg-model-b"
  ]
}
```

改完 `git push` → Render 自动重建 → 客户端 `model` 填 `ocg-free` 即可。
（如新增了真实模型名，记得同步在 New API 令牌的模型限制里放开。）

---

## 7. 后台管理入口（不变）

想进 New API 后台，直接访问根域名（不用记 3000 端口）：

```
https://你的服务.onrender.com/
```

路由层会把非 `/v1/chat/completions`、`/v1/models` 的请求原样代理到 New API 后台。
