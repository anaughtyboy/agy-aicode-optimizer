---
name: agy-aicode-optimizer
description: Google Antigravity CLI (agy) 与 Google AICode 路由性能诊断及调优技能。当用户反馈 agy 启动卡顿、Gemini/Claude 响应异常缓慢、日志出现 FetchConfig 超时 (context deadline exceeded) 或 CCPA 路由降级、以及排查代理 TUN/Fake-IP 延迟问题时触发。
---

# AGY & Google AICode 路由诊断与调优 SOP

本技能用于排查并修复 `agy` 启动时请求 `aicode.googleapis.com` 拉取实验配置（`FetchConfig`）因超过 **~1.5 秒**阈值而触发 CCPA 降级回退的问题。

## Agent 标准执行协议（SOP）

面对用户的性能或卡顿反馈，**必须严格按以下顺序执行，严禁跳过诊断直接盲推配置**：

1. **执行结构化诊断**：定位本 Skill 所在目录下的 `scripts/diagnose.sh`（使用相对路径定位，禁止硬编码绝对路径），执行：
   ```bash
   bash scripts/diagnose.sh --json
   ```
2. **基于 JSON 事实归因**：
   - **优先核验白盒控制面（若 `proxy_control_plane.status == "ok"`）**：
     - 直接提取 `matched_rule`、`policy_chain`、当前物理节点 `active_node` 与测速延迟，向用户点明当前分流事实，杜绝模糊推测；
     - 若 `proxy_control_plane.status == "unauthorized"`，顺带提示用户：导出 `CLASH_SECRET` / `MIHOMO_SECRET` 或 `SURGE_API_KEY` 可开启白盒透视；
     - 若为 `"unavailable"`，静默依赖黑盒指标继续诊断，不报错、不打断流程。
   - **结合决策矩阵**：依据返回字段向用户汇报明确结论。
3. **确认代理栈并精准输出**：若判定为网络/DNS 链路问题，先确认用户使用的代理客户端（Clash/Mihomo、Surge、Sing-box 或其他），仅输出对应客户端的闭环配置。
4. **验证提醒**：明确告知用户修改配置后需**完全退出并重启 `agy` 进程**，再重新运行诊断脚本验证。

---

## 诊断结果决策矩阵

| JSON 关键字段条件 | 根因判定 | 建议动作 |
| :--- | :--- | :--- |
| `network.status == "unreachable"` | 代理断连、节点不可用或终端代理变量异常 | 检查 `proxy_env` 及本地代理连通性，排除基础断网后再做路由优化 |
| `proxy_control_plane.status == "ok"` 且 `matched_rule` 包含 `MATCH` / `FINAL` / `DIRECT` | **分流规则漏命中**（绕过 Fake-IP 后未开 sniffer 嗅探，或缺少规则） | 明确指出流量掉入了兜底规则或直连；要求补全精准 `DOMAIN` 规则并开启 TLS SNI 嗅探 |
| `proxy_control_plane.active_node.delay_ms > 400` 且 `alternatives` 非空 | **当前物理节点高延迟** | 直接报出当前节点名与延迟，并列出 `alternatives` 中同组更优备选节点建议用户手动切换 |
| `proxy_control_plane.active_node.name` 命中高风险/非支持地区关键词（如 `HK` / `RU` / `CN`） | **地区路由不兼容或绕路风险** | 提示 Google AICode / Gemini 在该区域可能存在可用性限制或额外中转跳数，建议切换至美区（US）、新加坡（SG）或日本（JP）优质节点 |
| `proxy_control_plane.mode == "direct"` | **代理处于全局直连模式** | 提示代理内核当前为 direct 模式，需切回 rule 模式 |
| `log_status == "degraded"` 或 `network.status == "slow"` (`total_s > 1.4`)，且 `dns.mode == "fake-ip"` | **典型 Fake-IP 握手超时降级** | 为核心域名配置 Fake-IP 绕过 + SNI 嗅探 + 防污染 DoH，并确保走低延迟节点 |
| `network.status == "slow"` 且 `dns.mode == "real-ip"` | 节点延迟过高、多跳链路震荡或上游 DNS 慢 | 切换低延迟美区/新加坡优质节点，检查 `dns_s` 与 `tls_s` 耗时占比 |
| `log_status == "healthy"` 且 `network.status == "ok"` | **网络与路由健康**，非客户端降级导致 | 向用户解释模型机制：高推理等级（High Thinking Effort）的长思维链前摇或长上下文（80k+ Token）预填充耗时 |
| `dns.mode == "failed"` | 本地 DNS 解析服务异常 | 检查代理内核 DNS 模块是否正常运行 |

---

## 核心优化域名清单

为避免通配符（如 `*.googleapis.com`）引发过宽的规则副作用，仅精确收敛以下关键域名：

* `aicode.googleapis.com`（FetchConfig 配置与 Mendel 路由）
* `cloudcode-pa.googleapis.com`（CCPA 生产端点）
* `daily-cloudcode-pa.googleapis.com`（CCPA 预发/降级端点）
* `oauth2.googleapis.com`（OAuth Token 续签）

---

## 代理客户端闭环调优方案

> [!IMPORTANT]
> **架构前提**：在 TUN 模式下绕过 Fake-IP 后，内核仅可见目标 IP。因此配置必须同时满足三要素：**绕过 Fake-IP** + **开启 TLS SNI 嗅探（防止域名规则失效）** + **指定海外防污染 DNS（防止本地解析污染）**。

### 1. Clash / Mihomo

```yaml
sniffer:
  enable: true
  sniff:
    TLS:
      ports: [443]

dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-filter:
    - 'aicode.googleapis.com'
    - 'cloudcode-pa.googleapis.com'
    - 'daily-cloudcode-pa.googleapis.com'
    - 'oauth2.googleapis.com'
  nameserver-policy:
    '+.googleapis.com':
      - 'https://1.1.1.1/dns-query'
      - 'https://8.8.8.8/dns-query'

rules:
  - DOMAIN,aicode.googleapis.com,PROXY
  - DOMAIN,cloudcode-pa.googleapis.com,PROXY
  - DOMAIN,daily-cloudcode-pa.googleapis.com,PROXY
  - DOMAIN,oauth2.googleapis.com,PROXY
```

### 2. Surge

```ini
[General]
always-real-ip = aicode.googleapis.com, cloudcode-pa.googleapis.com, daily-cloudcode-pa.googleapis.com, oauth2.googleapis.com

[Rule]
DOMAIN,aicode.googleapis.com,PROXY
DOMAIN,cloudcode-pa.googleapis.com,PROXY
DOMAIN,daily-cloudcode-pa.googleapis.com,PROXY
DOMAIN,oauth2.googleapis.com,PROXY
```

### 3. Sing-box

```json
{
  "dns": {
    "rules": [
      {
        "domain": [
          "aicode.googleapis.com",
          "cloudcode-pa.googleapis.com",
          "daily-cloudcode-pa.googleapis.com",
          "oauth2.googleapis.com"
        ],
        "server": "remote_doh"
      }
    ]
  },
  "route": {
    "rules": [
      {
        "action": "sniff"
      },
      {
        "domain": [
          "aicode.googleapis.com",
          "cloudcode-pa.googleapis.com",
          "daily-cloudcode-pa.googleapis.com",
          "oauth2.googleapis.com"
        ],
        "outbound": "proxy"
      }
    ]
  }
}
```
*(注：请将 `remote_doh` 与 `proxy` 替换为实际配置中的海外 DoH DNS 节点与代理出站标签。)*
