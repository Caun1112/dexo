# Dexo 无状态 Web Push → APNs 端到端加密实施方案

> 状态：本地实现完成；等待配置中继域名、APNs Provider Key，并在 Apple Developer 中为 App ID 启用 Push Notifications 后进行端到端验收
> 编写日期：2026-07-20
> 目标实施位置：`/Users/wxl/Documents/dexo`
> 服务端语言：Go
> 本文是后续实现、测试和验收的执行清单；开始编码前先重新阅读仓库根目录的 `AGENTS.md`。

## 1. 最终目标

为 Dexo 增加按论坛启用的系统推送通知，复用 Discourse Core 的 Web Push 发送能力，同时满足以下隐私要求：

1. Dexo 推送中继不建立用户、论坛或设备数据库。
2. 中继不持久化 APNs device token、论坛账号、Web Push 私钥、通知正文或设备映射。
3. Web Push 通知正文从 Discourse 到 iOS Notification Service Extension 全程保持 RFC 8291 密文；中继和 Apple 只接触密文。
4. Web Push 接收私钥只保存在用户设备的共享 Keychain 中。
5. APNs token 仅在两个时刻短暂出现在中继内存中：创建密封 endpoint 时，以及收到 Web Push、准备请求 APNs 时。
6. 中继同步转发 APNs，不使用数据库、磁盘队列或消息队列。

这里的“无状态”专指中继没有每用户持久化状态。以下信息仍然不可避免：

- Discourse 论坛会保存密封后的 endpoint、`p256dh` 公钥和 `auth`。
- 中继必须保存全局 endpoint 密封密钥和 Apple APNs Provider 私钥；它们不是用户数据。
- APNs 必须在请求期间看到 device token，才能完成设备路由。
- Dexo 本机必须保存精确的订阅信息，以便续期和退订。

## 2. 已确认的可行性依据

- Discourse 接受登录用户提交的任意 Web Push subscription，并保存 `endpoint`、`p256dh` 和 `auth`：
  <https://github.com/discourse/discourse/blob/main/app/controllers/push_notification_controller.rb>
- Discourse 将通知 JSON 按 RFC Web Push 加密，然后直接向保存的 endpoint 发起 HTTPS POST；当前连接、读取和 TLS 超时均为 5 秒：
  <https://github.com/discourse/discourse/blob/main/app/services/push_notification_pusher.rb>
- Discourse 对 endpoint 出站请求执行 SSRF/DNS rebinding 防护，因此 endpoint 必须解析到公网地址：
  <https://github.com/discourse/discourse/blob/main/lib/freedom_patches/web_push_request.rb>
- RFC 8291 定义了 P-256 ECDH、16 字节 `auth`、HKDF-SHA256 和 `aes128gcm` 解密流程：
  <https://www.rfc-editor.org/rfc/rfc8291.html>
- iOS Notification Service Extension 可在展示前解密并替换远程通知；APNs payload 必须包含可见 `alert` 和 `mutable-content: 1`：
  <https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications>
- 普通 APNs payload 上限为 4096 字节：
  <https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns>

## 3. 总体架构

```text
首次启用
────────
Dexo
  ├─ 请求 iOS 通知权限并获取最新 APNs token
  ├─ 本地生成 Web Push P-256 私钥、公钥、16B auth、subscriptionID
  ├─ POST APNs token + subscriptionID + forum/VAPID 信息到 Go 中继
  │    └─ 中继只在内存中生成 sealed endpoint，响应后丢弃输入
  ├─ 私钥/auth/forum 绑定写入共享 Keychain
  └─ endpoint + p256dh + auth POST 到论坛 /push_notifications/subscribe.json

通知投递
────────
Discourse
  └─ RFC 8291 加密通知正文并 POST sealed endpoint
       ↓
Go 中继
  ├─ 解开 endpoint，短暂取得 APNs token、subscriptionID、VAPID 绑定
  ├─ 校验 VAPID；不解密 Web Push body
  ├─ 将原始密文 Base64URL 包装进 APNs payload
  └─ 同步发送 APNs，随后清除请求相关引用
       ↓
Notification Service Extension
  ├─ 根据 subscriptionID 从共享 Keychain 读取私钥/auth
  ├─ 解密 RFC 8291 aes128gcm body
  ├─ 校验 forum base URL
  └─ 替换 title/body/userInfo 后展示
```

## 4. 信任边界与可见信息

| 参与方 | 可见信息 | 不应可见的信息 |
| --- | --- | --- |
| Discourse 论坛 | 通知原文、密封 endpoint、Web Push 公钥/auth | APNs token 明文、Web Push 私钥 |
| Dexo 中继 | 请求期间的 APNs token、subscriptionID、Web Push 密文、论坛 VAPID 公钥 | 通知原文、论坛登录凭据、Web Push 私钥 |
| Apple APNs | APNs token、Dexo 通用 fallback 文案、Web Push 密文 | Discourse 通知原文、论坛登录凭据 |
| Dexo App/扩展 | APNs token、Web Push 私钥/auth、解密后正文 | — |

必须把“中继不留存用户信息”落实到应用日志、反向代理日志、CDN/WAF、APM、崩溃转储和云平台请求采样，而不只是“不建数据库”。

## 5. 计划新增的仓库结构

```text
/Users/wxl/Documents/dexo
├── Packages/
│   └── PushCrypto/
│       ├── Package.swift
│       ├── Sources/PushCrypto/
│       │   ├── Base64URL.swift
│       │   ├── RFC8188Record.swift
│       │   ├── WebPushKeyMaterial.swift
│       │   └── WebPushDecryptor.swift
│       └── Tests/PushCryptoTests/
│           ├── RFC8291VectorTests.swift
│           └── WebPushFailureTests.swift
├── dexo/
│   ├── Core/Push/
│   │   ├── APNSTokenProvider.swift
│   │   ├── PushConfiguration.swift
│   │   ├── PushKeychainStore.swift
│   │   ├── PushRelayAPI.swift
│   │   ├── PushSubscriptionCoordinator.swift
│   │   └── PushDeepLinkCoordinator.swift
│   ├── Database/Models/
│   │   └── PushSubscriptionRecord.swift
│   └── Features/ForumDetail/Me/
│       └── PushNotificationSettingsViewController.swift
├── DexoNotificationService/
│   ├── NotificationService.swift
│   ├── Info.plist
│   ├── DexoNotificationService.entitlements
│   └── Localizable.xcstrings
├── server/
│   └── push-relay/
│       ├── cmd/push-relay/main.go
│       ├── internal/
│       │   ├── apns/client.go
│       │   ├── config/config.go
│       │   ├── endpoint/envelope.go
│       │   ├── endpoint/sealer.go
│       │   ├── httpapi/endpoints.go
│       │   ├── httpapi/health.go
│       │   ├── httpapi/webpush.go
│       │   ├── privacy/logging.go
│       │   └── vapid/validator.go
│       ├── .env.example
│       ├── Caddyfile.example
│       ├── Dockerfile
│       ├── README.md
│       ├── go.mod
│       └── go.sum
├── docs/
│   └── push-relay-implementation-plan.md
└── Project.swift
```

服务端代码固定放在 `server/push-relay`，不拆成另一个仓库。

## 6. 协议设计

### 6.1 获取论坛 VAPID 公钥

Dexo 对当前论坛请求：

```http
GET <forum-base-url>/site/settings.json
Accept: application/json
```

读取：

```json
{
  "enable_desktop_push_notifications": true,
  "vapid_public_key_bytes": "4|184|..."
}
```

处理规则：

1. `enable_desktop_push_notifications` 必须为 `true`。
2. 将 `vapid_public_key_bytes` 按 `|` 拆成 0...255 的字节。
3. 结果必须恰好是 65 字节、首字节为 `0x04`，并且是有效 P-256 非压缩公钥。
4. 转为无 padding 的 Base64URL，作为 `forum_vapid_public_key`。
5. 如果字段不存在，则 UI 显示论坛不支持该推送方案，不尝试注册。

### 6.2 Dexo 本地生成订阅密钥

每个“Dexo 安装 × 论坛 × 论坛账号”生成独立材料：

- `subscription_id`：16 或 32 个安全随机字节，Base64URL 无 padding。
- `ua_private_key`：P-256 Key Agreement 私钥。
- `p256dh`：对应的 65 字节非压缩公钥，Base64URL 无 padding。
- `auth`：16 个安全随机字节，Base64URL 无 padding。

Keychain 保存的记录：

```json
{
  "version": 1,
  "subscription_id": "...",
  "forum_base_url": "https://forum.example.com",
  "forum_username": "alice",
  "ua_private_key": "<base64url raw private key>",
  "p256dh": "...",
  "auth": "..."
}
```

要求：

- App 与 Notification Service Extension 使用同一个 Keychain Access Group。
- 使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，保证设备首次解锁后锁屏状态下扩展可读取，同时不随备份迁移到其他设备。
- Keychain key 使用 `subscription_id`，不使用论坛域名或用户名，避免系统诊断信息暴露关联关系。
- APNs token 明文不写入 Keychain、GRDB 或 UserDefaults；本机只保存其 SHA-256 fingerprint 用于判断是否轮换。

### 6.3 创建密封 endpoint

接口：

```http
POST https://<PUSH_RELAY_DOMAIN>/v1/endpoints
Content-Type: application/json
Cache-Control: no-store
```

请求：

```json
{
  "version": 1,
  "apns_token": "<base64url raw token bytes>",
  "apns_environment": "production",
  "subscription_id": "<base64url random id>",
  "forum_base_url": "https://forum.example.com",
  "forum_vapid_public_key": "<base64url uncompressed P-256 key>"
}
```

约束：

- `forum_base_url` 只接受规范化 HTTPS URL；保留合法的 Discourse 子路径，禁止 userinfo、fragment 和非 HTTPS scheme。
- APNs topic 不接受客户端输入，固定读取服务端 `DEXO_APNS_TOPIC`，避免中继被用于其他 App。
- token、subscription ID、公钥均做严格长度及曲线校验。
- 请求体上限 4 KB。
- 返回 `Cache-Control: no-store`。
- 应用层及代理层不记录 request body。

响应：

```json
{
  "version": 1,
  "endpoint": "https://<PUSH_RELAY_DOMAIN>/v1/webpush/<KID>.<SEALED_PAYLOAD>",
  "expires_at": "2027-07-20T00:00:00Z"
}
```

响应必须先持久化到 Dexo 本机，然后才能调用 Discourse。若调用 Discourse 超时，重试同一份 subscription，不重新申请 endpoint。

### 6.4 Sealed endpoint 格式

使用 Go 标准库 AES-256-GCM：

```text
URL path  = /v1/webpush/{kid}.{base64url(nonce || ciphertext || tag)}
nonce     = 12 个随机字节，每次密封重新生成
key       = DEXO_SEAL_KEYS_JSON[kid] 中的 32 字节密钥
AAD       = "dexo-push-endpoint/v1\n" || kid || "\n" || configuredRelayOrigin
```

加密前的紧凑 JSON envelope：

```json
{
  "v": 1,
  "iat": 1784486400,
  "exp": 1816022400,
  "sid": "<subscription-id>",
  "at": "<base64url-apns-token>",
  "ae": "production",
  "fb": "https://forum.example.com",
  "vk": "<forum-vapid-public-key>"
}
```

规则：

- 默认 endpoint TTL 为一年，通过配置调整。
- `kid` 明文仅用于选择全局密钥，并通过 AAD 防篡改。
- 解密后校验版本、时间、长度、APNs 环境和 VAPID 公钥。
- 不允许把 APNs Provider key、用户账号、论坛 API key 或 Web Push 私钥放入 envelope。

### 6.5 注册到 Discourse

接口：

```http
POST <forum-base-url>/push_notifications/subscribe.json
Content-Type: application/json
User-Api-Key: <existing-key>
```

请求：

```json
{
  "subscription": {
    "endpoint": "https://<PUSH_RELAY_DOMAIN>/v1/webpush/<KID>.<SEALED_PAYLOAD>",
    "keys": {
      "p256dh": "<device-generated-public-key>",
      "auth": "<device-generated-auth>"
    }
  },
  "send_confirmation": false
}
```

注意：

- 当前 Dexo User API Key 已申请 `write` scope，可调用该 POST，无需增加 Discourse `push` scope 或 `push_url`。
- Cookie 登录走现有 CSRF 获取与 Cookie 隔离逻辑。
- 默认使用 `send_confirmation: false`，保证网络不确定时可幂等重试。
- Discourse 按完整 JSON 去重和退订，因此 Dexo 必须保存 endpoint、`p256dh`、`auth` 的精确值。
- 启用后检查当前 Discourse 版本的 `push_notification_level`。若字段存在且为 `none`，经用户本次明确操作将其更新为 `all`；旧版本不支持该字段时不视为失败。

退订：

```http
POST <forum-base-url>/push_notifications/unsubscribe.json
```

```json
{
  "subscription": {
    "endpoint": "<exact same endpoint>",
    "keys": {
      "p256dh": "<exact same p256dh>",
      "auth": "<exact same auth>"
    }
  }
}
```

退订成功后再删除本机 Keychain 和 GRDB 记录。退出论坛账号前必须先尝试退订，不能先撤销 User API Key。

### 6.6 中继接收 Web Push

接口：

```http
POST /v1/webpush/{kid}.{sealed}
Content-Type: application/octet-stream
Content-Encoding: aes128gcm
Authorization: vapid t=<JWT>, k=<public-key>
```

处理顺序：

1. 在读取大 body 前校验 path 长度、method 和 content type。
2. 解密 sealed endpoint，取得 APNs token、environment、subscription ID、论坛绑定 VAPID key。
3. 校验 envelope 未过期。
4. 严格解析 VAPID header，仅接受 ES256。
5. JWT `aud` 必须等于配置的 relay origin，`exp` 必须有效且不能超出协议允许窗口。
6. `k` 必须与 envelope 中 `vk` 常量时间比较一致，并用该公钥验证 JWT。
7. Web Push body 不解密、不写盘、不进入日志。
8. body 长度不得超过 `DEXO_MAX_WEBPUSH_BODY_BYTES`；初始值设为 2800，实际以 APNs 最终 JSON 序列化后不超过 4096 字节为准。
9. Base64URL 编码原始 body，组装 APNs payload。
10. 在 Discourse 5 秒超时内同步等待 APNs 结果并返回映射状态。

### 6.7 APNs payload

```json
{
  "aps": {
    "alert": {
      "title-loc-key": "push.encrypted_fallback.title",
      "loc-key": "push.encrypted_fallback.body"
    },
    "mutable-content": 1,
    "sound": "default"
  },
  "dexo": {
    "v": 1,
    "sid": "<subscription-id>",
    "wp": "<base64url-original-webpush-body>"
  }
}
```

APNs headers：

```text
apns-push-type: alert
apns-priority: 10
apns-topic: com.eilgnaw.dexo
apns-expiration: 0
```

初始版本将 `apns-expiration` 设为 `0`，避免 APNs 离线持久化并保持隐私优先；代价是设备离线时通知可能丢失。后续如需要离线送达，只允许把“Apple 暂存密文”的时长做成明确配置。

中继响应映射：

| APNs 结果 | 中继返回给 Discourse | 行为 |
| --- | --- | --- |
| `200` | `201 Created` | 投递请求成功 |
| `BadDeviceToken` / `DeviceTokenNotForTopic` / `Unregistered` | `410 Gone` | 促使 Discourse 删除失效 subscription |
| Web Push body 超限 | `413 Payload Too Large` | 不请求 APNs |
| VAPID 无效 | `401 Unauthorized` | 不请求 APNs |
| endpoint 过期或密钥已移除 | `410 Gone` | 促使 Discourse 删除 subscription |
| APNs `429` | `429 Too Many Requests` | 本次丢失，不持久化重试 |
| APNs `500/503` 或超时 | `503 Service Unavailable` | 本次丢失，不持久化重试 |

### 6.8 iOS 本地解密

Notification Service Extension：

1. 从 `request.content.userInfo["dexo"]` 读取版本、`sid` 和密文。
2. 按 `sid` 从共享 Keychain 取出 P-256 私钥、`p256dh`、`auth` 和绑定的 forum base URL。
3. Base64URL 解码 `wp`。
4. 解析 RFC 8188 `aes128gcm` 单 record：salt、record size、sender ephemeral public key、ciphertext 和 tag。
5. 验证 sender/receiver P-256 公钥合法。
6. 按 RFC 8291 执行 ECDH、两阶段 HKDF-SHA256、AES-128-GCM open。
7. 验证 record delimiter 为 `0x02` 并删除 padding。
8. JSON 解码 Discourse payload。
9. `base_url` 必须与 Keychain 绑定的 canonical forum base URL 一致；不一致则拒绝替换内容。
10. 修改 `UNMutableNotificationContent`：

```text
title            ← payload.title
body             ← payload.body
subtitle         ← App Group 中按 base_url 匹配的论坛名称与域名
attachments      ← App 预缓存到 App Group 的论坛 PNG 图标（存在时）
threadIdentifier ← payload.tag（存在时）
userInfo          ← 加入已校验的 forum base URL 和 relative URL
```

11. 调用 `contentHandler`。
12. `serviceExtensionTimeWillExpire()` 始终返回本地化通用 fallback，禁止显示密文或错误详情。

iOS 不允许远程通知替换左侧的应用主图标；该位置始终显示 Dexo 图标。论坛图标只能作为
`UNNotificationAttachment` 交给系统展示。主 App 在启动及订阅时把已添加论坛的名称、
规范化域名和栅格化 PNG 图标同步到 `group.com.eilgnaw.dexo.push`，扩展不为图标临时联网。

主 App 点击通知后只处理扩展写入且已校验的 `forum_base_url` 与相对 `url`，复用现有论坛选择和 TopicDetail 深链逻辑；不直接信任未解密的 APNs 自定义字段。

## 7. Go 中继实现要求

### 7.1 技术选型

- Go 版本在实现时固定为仓库当前工具链 `1.26.1`，加入 `.mise.toml`。
- HTTP：标准库 `net/http`，不引入 Web 框架。
- 日志：标准库 `log/slog`，只记录 route template、结果类别、耗时和随机 request ID。
- Endpoint 密封：标准库 `crypto/aes` + `cipher.GCM`。
- VAPID JWT：`github.com/golang-jwt/jwt/v5`，锁定具体版本。
- APNs：`github.com/sideshow/apns2`，锁定具体版本，并维持 production/development 两个长连接客户端。
- 配置：标准库环境变量解析，不增加配置中心或远程依赖。

### 7.2 Go 接口抽象

为可测试性定义：

```go
type EndpointSealer interface {
    Seal(EndpointClaims) (string, error)
    Open(kid, token string) (EndpointClaims, error)
}

type VAPIDValidator interface {
    Validate(headers http.Header, expectedKey []byte, audience string, now time.Time) error
}

type APNSSender interface {
    Send(ctx context.Context, environment Environment, deviceToken []byte, payload []byte) APNSResult
}
```

HTTP handler 只编排上述接口，不直接持有密钥解析或 APNs SDK 细节。

### 7.3 服务端配置占位符

`server/push-relay/.env.example` 计划内容：

```dotenv
# Public endpoint
DEXO_RELAY_BASE_URL=https://<PUSH_RELAY_DOMAIN>
DEXO_HTTP_LISTEN_ADDR=:8080

# Stateless endpoint envelope
DEXO_ACTIVE_SEAL_KID=<ACTIVE_KEY_ID>
DEXO_SEAL_KEYS_JSON={"<ACTIVE_KEY_ID>":"<BASE64URL_32_BYTE_AES_KEY>"}
DEXO_ENDPOINT_TTL=8760h

# Request limits and deadlines; total must remain below Discourse's 5s timeout
DEXO_MAX_ENDPOINT_REQUEST_BYTES=4096
DEXO_MAX_WEBPUSH_BODY_BYTES=2800
DEXO_HTTP_REQUEST_TIMEOUT=4500ms
DEXO_APNS_TIMEOUT=3000ms

# Apple APNs provider credentials
DEXO_APNS_TEAM_ID=<APPLE_TEAM_ID>
DEXO_APNS_KEY_ID=<APPLE_APNS_KEY_ID>
DEXO_APNS_PRIVATE_KEY_PATH=/run/secrets/AuthKey_<APPLE_APNS_KEY_ID>.p8
DEXO_APNS_TOPIC=com.eilgnaw.dexo
DEXO_ALLOW_APNS_DEVELOPMENT=true
DEXO_ALLOW_APNS_PRODUCTION=true
DEXO_APNS_EXPIRATION_SECONDS=0

# Abuse protection without persistent identity storage
DEXO_RATE_LIMIT_RPS=<REQUESTS_PER_SECOND>
DEXO_RATE_LIMIT_BURST=<BURST>
DEXO_TRUSTED_PROXY_CIDRS=<OPTIONAL_PROXY_CIDRS>

# Privacy-safe observability
DEXO_LOG_LEVEL=info
DEXO_METRICS_ENABLED=false
```

真实密钥只通过部署环境或 secret mount 提供，不提交到 Git。

### 7.4 密钥轮换

1. `DEXO_SEAL_KEYS_JSON` 是 `kid → key` 的全局 keyring。
2. 新增密钥时先部署包含新旧 key 的版本，再切换 `DEXO_ACTIVE_SEAL_KID`。
3. Dexo 在 endpoint 距过期不足 30 天时续期并替换论坛 subscription。
4. 旧 key 至少保留 `endpoint TTL + 30 天宽限期`。
5. 删除旧 key 后，对旧 endpoint 返回 `410`。
6. APNs `.p8` 独立轮换，不改变 endpoint。

## 8. iOS 工程改造

### 8.1 Tuist 与签名能力

修改 `Project.swift`：

1. 增加本地包 `Packages/PushCrypto`。
2. App target 增加 Push Notifications、Keychain Sharing 和 App Groups entitlement。
3. 新增 `DexoNotificationService` app extension target：
   - product：app extension
   - bundle ID：`com.eilgnaw.dexo.NotificationService`
   - deployment target：iOS 16.0
   - 依赖 `PushCrypto`
   - 与主 App 使用相同 Keychain Access Group
   - 与主 App 使用 `group.com.eilgnaw.dexo.push` App Group
4. 主 App embedding 该扩展。
5. 增加 relay host build setting，默认使用不可路由占位符并关闭功能。

建议本地未提交配置：

```toml
# .mise.local.toml
[env]
TUIST_DEVELOPMENT_TEAM = "<APPLE_TEAM_ID>"
TUIST_PUSH_RELAY_HOST = "<PUSH_RELAY_DOMAIN>"
```

`Project.swift` 使用 `Environment.pushRelayHost` 读取 host，代码固定使用 HTTPS，避免把 scheme 分散到配置中。

修改后必须执行：

```bash
make generate
```

### 8.2 APNs token 生命周期

在 `AppDelegate` 增加：

- `registerForRemoteNotifications()` 调用。
- `didRegisterForRemoteNotificationsWithDeviceToken`。
- `didFailToRegisterForRemoteNotificationsWithError`。

由 `APNSTokenProvider` actor/对象向订阅流程提供当前启动周期拿到的 token，不把 token 明文持久化。每次 App 启动都重新向 APNs 获取当前 token。

本地数据库只保存 token 的 SHA-256 fingerprint：

- fingerprint 相同：保留当前 endpoint。
- fingerprint 改变：逐个论坛先用旧 JSON 退订，再创建并订阅新 endpoint。
- 旧退订失败：保留待重试记录，不立即删除旧 Keychain 材料；endpoint 到期或 APNs 返回永久错误后由 Discourse 清理。

### 8.3 本地数据模型

GRDB 新表建议字段：

```text
push_subscriptions
  subscriptionID       TEXT PRIMARY KEY
  forumBaseURL         TEXT NOT NULL
  forumUsername        TEXT NOT NULL
  endpoint             TEXT NOT NULL
  p256dh               TEXT NOT NULL
  keychainKey           TEXT NOT NULL
  apnsTokenFingerprint BLOB NOT NULL
  expiresAt             DATETIME NOT NULL
  createdAt             DATETIME NOT NULL
  pendingUnsubscribe    BOOLEAN NOT NULL DEFAULT FALSE
```

`auth` 和私钥只在共享 Keychain；数据库中的 `keychainKey` 即 subscription ID。

### 8.4 个人中心 UI

在当前论坛的 `MeViewController` 增加“推送通知”入口，仅登录用户显示。进入设置页后显示：

- 已启用
- 未启用
- 正在注册
- 系统权限已拒绝，并提供跳转系统设置
- 当前论坛不支持 Web Push
- 中继未配置/不可用
- 订阅即将过期或续期失败

所有字符串使用 `String(localized:)`，并在 `dexo/Localizable.xcstrings` 和扩展自己的 string catalog 中提供 English 与 Simplified Chinese。

建议 key：

```text
push.settings.title
push.settings.enable
push.settings.disable
push.settings.registering
push.settings.permission_denied
push.settings.open_system_settings
push.settings.forum_unsupported
push.settings.relay_unavailable
push.settings.retry
push.encrypted_fallback.title
push.encrypted_fallback.body
```

颜色继续通过 `ThemeManager.shared` 在展示时设置。

### 8.5 退出登录与删除论坛

必须调整调用顺序：

1. 读取本机保存的精确 subscription。
2. 使用仍有效的 User API Key 或 Cookie 会话调用论坛 unsubscribe。
3. 成功后删除 Keychain/GRDB subscription。
4. 最后执行现有论坛 logout/revoke API key。

如果离线或论坛不可达：

- 标记 `pendingUnsubscribe = true` 并保留旧凭据到有限重试窗口；或者明确提示用户退订尚未完成。
- 不允许静默先撤销认证再让旧 subscription 永久留在论坛。
- App 被卸载时无法主动退订；依赖 APNs token 失效后中继返回 `410`，以及 endpoint 的固定到期时间。

## 9. 实施阶段与完成条件

### 阶段 A：共享密码学包

- [ ] 创建 `Packages/PushCrypto`。
- [ ] 实现 Base64URL、P-256 key material 和 RFC 8188 record parser。
- [ ] 使用 CryptoKit 实现 RFC 8291 解密。
- [ ] 用 RFC 8291 第 5 节公开向量验证得到原始明文。
- [ ] 覆盖错误 auth、错误私钥、篡改 tag、非法曲线点、非法 delimiter、超大 record。
- [ ] `cd Packages/PushCrypto && swift test` 全部通过。

### 阶段 B：Go 无状态中继

- [ ] 在 `server/push-relay` 初始化 Go module。
- [ ] 完成配置校验，缺少密钥时拒绝启动。
- [ ] 完成 AES-GCM endpoint seal/open。
- [ ] 完成 `POST /v1/endpoints`。
- [ ] 完成 VAPID ES256/aud/exp/key binding 验证。
- [ ] 完成 APNs payload builder 和大小限制。
- [ ] 接入 APNs production/development 客户端。
- [ ] 完成 `POST /v1/webpush/{sealed}` 及状态映射。
- [ ] 增加 `/healthz` 和 `/readyz`，不得泄露配置。
- [ ] Docker image 使用非 root 用户、只读 root filesystem，并禁用 core dump。
- [ ] 所有测试、race detector 和 fuzz smoke test 通过。

执行：

```bash
cd server/push-relay
go test ./...
go test -race ./...
go vet ./...
```

### 阶段 C：iOS 能力与通知扩展

- [ ] 修改 Tuist targets、entitlements、Keychain Access Group 和 relay host 配置。
- [ ] 执行 `make generate`。
- [ ] 添加 APNs token provider。
- [ ] 添加共享 Keychain store。
- [ ] 添加 Notification Service Extension。
- [ ] Extension 使用 `PushCrypto` 完成本地解密、forum 绑定校验和 fallback。
- [ ] App 增加通知点击深链路由。
- [ ] 编译通过且 entitlement 正常嵌入签名产物。

### 阶段 D：论坛订阅与 UI

- [ ] 实现 `/site/settings.json` VAPID discovery。
- [ ] 实现 relay endpoint 创建接口。
- [ ] 实现 Discourse subscribe/unsubscribe route。
- [ ] 添加本地 GRDB migration 和恢复逻辑。
- [ ] 增加个人中心入口、状态页和中英文翻译。
- [ ] 将退出账号、删除论坛和 APNs token 轮换接入退订流程。
- [ ] 处理 API Key 与 Cookie 两种登录模式。

### 阶段 E：端到端验证与上线

- [ ] 使用专门测试域名 `<PUSH_RELAY_STAGING_DOMAIN>` 部署 staging。
- [ ] 使用测试论坛和 development APNs 环境创建全新 subscription。
- [ ] 验证中继只看到 Web Push 密文，扩展能展示 Discourse title/body。
- [ ] 验证点击通知打开正确论坛、主题和楼层。
- [ ] 验证错误私钥只显示通用 fallback。
- [ ] 验证 APNs 永久 token 错误映射为 `410` 并触发论坛删除 subscription。
- [ ] 验证 endpoint 篡改、过期、错误 VAPID、超大 body 全部被拒绝。
- [ ] 审计应用、代理、CDN、APM 和崩溃日志，搜索不得出现 token、完整 endpoint、sid、论坛 URL 或通知正文。
- [ ] 再切换 production 域名 `<PUSH_RELAY_DOMAIN>` 和 production APNs。

## 10. 自动化测试矩阵

### Go 单元/集成测试

- AES-GCM seal/open round trip。
- nonce 唯一性和篡改检测。
- 未知/过期 `kid`。
- envelope 过期、未来 `iat`、非法 APNs token、非法论坛 URL。
- VAPID 正常、错误 aud、错误 exp、错误签名、错误公钥绑定、非 ES256。
- APNs payload 4096 字节边界。
- APNs 状态码到 Web Push 状态码映射。
- handler deadline 小于 Discourse 5 秒。
- 日志捕获测试：敏感 fixture 不得出现在任何日志字段。
- `go test -race ./...`。
- 对 endpoint parser、VAPID header parser 和 JSON body 做 fuzz smoke test。

### Swift 单元测试

- RFC 8291 官方向量。
- 正确 Discourse JSON 解密。
- Base64URL 无 padding。
- 错误 tag/auth/private key。
- 非法 record size、keyid length、delimiter、padding。
- forum base URL 绑定不一致。
- Keychain record Codable 往返使用测试替身，不在单元测试写真实共享 Keychain。

### App 集成测试

- 权限未决定、允许、拒绝三种 UI 状态。
- endpoint 创建成功但论坛注册超时后，复用同一 subscription 重试。
- 多论坛订阅互不共用 endpoint、密钥或 sid。
- APNs token fingerprint 改变触发全部订阅轮换。
- 退出登录先退订再 revoke。
- Notification Service Extension 超时/解密失败显示本地化 fallback。

## 11. 隐私和安全检查清单

- [ ] 中继无数据库依赖、无持久化 volume、无磁盘队列。
- [ ] `/v1/endpoints` body、完整 Web Push path、Authorization、APNs token、sid 和 body 不记录日志。
- [ ] 反向代理关闭 access log，或只记录 route template，不记录原始 URI。
- [ ] CDN/WAF/APM 关闭 request body、path parameter 和 header 采样。
- [ ] 云平台 crash/core dump 禁用或使用不含请求内存的策略。
- [ ] 所有 HTTP 响应增加 `Cache-Control: no-store`；敏感响应不进入 CDN cache。
- [ ] endpoint AES key 与 APNs `.p8` 使用部署 secrets/KMS，不在环境诊断页面输出。
- [ ] AES-GCM nonce 来自 `crypto/rand`，禁止计数器重启或固定 nonce。
- [ ] 所有 P-256 公钥做曲线点验证。
- [ ] VAPID key 与 sealed endpoint 中论坛 key 绑定。
- [ ] 只允许配置的 APNs topic。
- [ ] body/path/request 有严格上限和 deadline。
- [ ] 不做跨论坛 endpoint 复用，避免论坛串联识别同一设备。
- [ ] 文档明确无队列意味着 at-most-once；不把丢通知误报为可靠投递。

## 12. 运维与部署占位符

部署前需要用户提供或创建：

```text
<PUSH_RELAY_STAGING_DOMAIN>
<PUSH_RELAY_DOMAIN>
<APPLE_TEAM_ID>
<APPLE_APNS_KEY_ID>
<APPLE_APNS_P8_FILE>
<ACTIVE_KEY_ID>
<BASE64URL_32_BYTE_AES_KEY>
<GO_MODULE_PATH_OR_GITHUB_OWNER>
<DEPLOY_TARGET>
```

建议生成 AES key：

```bash
openssl rand -base64 32
```

实现时转换并校验为 32 字节 Base64URL；不要把实际输出粘贴进本文或提交到 Git。

部署约束：

- 公网 HTTPS，TLS 1.2+。
- DNS 必须解析到公网 IP，不能指向内网或 loopback。
- 容器无持久化 volume，APNs `.p8` 只读 secret mount 除外。
- 至少两个实例时仍完全无共享数据库；所有实例持有相同 seal keyring 和 APNs Provider key。
- health check 不访问 APNs、不生成用户数据。
- 滚动发布时先保证新旧实例都包含完整 seal keyring。

## 13. 已接受的限制

1. 无持久化队列，因此通知是 at-most-once；中继或 APNs 暂时失败时消息丢失。
2. APNs payload 上限 4096 字节，Base64URL 会使 Web Push 密文增大约三分之一；初期限制原始 Web Push body 为约 2800 字节。
3. Notification Service Extension 未运行、超时、设备重启后尚未首次解锁或本机 Keychain 丢失时，只显示通用 fallback。
4. 严格无状态无法记录消息 nonce 来阻止 TLS 终止层内部的短时重放；VAPID、TLS、不可猜 endpoint 和 APNs 行为降低风险，但不能提供跨请求的绝对 replay prevention。
5. App 被删除或本地数据损坏时不能主动向所有论坛退订；依靠 APNs 永久错误和 endpoint 到期最终清理。
6. 论坛自身知道通知正文，这是通知产生端，端到端加密只保护“论坛 → Dexo 设备”之间的中继和 APNs 路径。

## 14. 明天开始实施时的顺序

1. 确认 Apple Team、App ID Push capability、APNs `.p8`、staging 域名和部署目标。
2. 创建 `Packages/PushCrypto`，先用 RFC 8291 官方向量把设备端解密做正确。
3. 创建 `server/push-relay`，完成 endpoint seal/open、VAPID 验证和 fake APNs 测试。
4. 修改 `Project.swift`，加入 Extension、entitlements、共享 Keychain 和 PushCrypto dependency；运行 `make generate`。
5. 接入 APNs token provider、relay API、Discourse subscribe/unsubscribe 和本地记录。
6. 增加个人中心 UI、中英文翻译、退出账号/删论坛清理逻辑。
7. 部署 staging 中继，做真实 development APNs 端到端验证。
8. 完成隐私日志审计后再启用 production。

## 15. iOS Simulator 与签名安全门槛

后续实施必须继续遵守仓库 `AGENTS.md`：

- `CODE_SIGNING_ALLOWED=NO` 的产物只允许做编译检查，绝不安装或启动。
- 不在已有、已启动或含用户数据的 Simulator 上做安装、卸载、替换、擦除或 UI 运行测试。
- 运行测试只能使用新建的一次性 Simulator，并且在任何 `simctl install/uninstall/erase` 前取得用户对具体操作的明确授权。
- 安装前验证 App 和 Notification Service Extension 均正常签名且含正确 APNs、Keychain Sharing entitlements。
- 任何可能替换 App 或影响数据容器/App Group 的操作前先做可恢复备份。

真实 APNs 验证优先使用明确授权的测试设备/TestFlight 或专门的 development 环境；不要把无签名 Simulator 编译产物用于运行验证。
