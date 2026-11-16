---
name: agy-aicode-optimizer
description: AGY CLI & Google AICode 路由优化与诊断技能。排查 Gemini/Claude 在 agy 中响应缓慢、FetchConfig 超时降级、DNS/Fake-IP 延迟等问题，并提供一键诊断脚本、Clash/Surge DNS 优化方案与前后效果基准对比。
---

# AGY & Google AICode 路由性能调优指南 (agy-aicode-optimizer)

本技能用于诊断与修复 Google Antigravity CLI (`agy`) 在使用 Gemini（尤其是带 Thinking Effort 的模型）时出现的**启动迟钝、路由回退降级（FetchConfig 超时）以及请求延迟过大**等问题。

---

## 流程一：思考与响应缓慢的原因诊断

当在 `agy` 中使用 `Gemini 3.8 Flash (High)` 或其他模型感觉极度缓慢时，核心原因通常分为两层：

### 1. 客户端网络/路由回退（可本地优化）
- **FetchConfig 超时降级**：
  AGY 启动时会请求 `https://aicode.googleapis.com/v1alpha:fetchConfig` 拉取最新实验特性及 Mendel 路由策略。
  > [!WARNING]
  > AGY 客户端对该配置拉取设置了极其严苛的超时阈值（约 **1.5 秒**）。
  > 在使用代理软件（如 Clash、Surge 等）的 TUN + Fake-IP 模式时，冷启动的 DNS 劫持与 TLS 多次握手极易突破 1.5s，触发：
  > `CCPA routed this account to AICode, but AICode FetchConfig failed, serving CCPA's flags: context deadline exceeded`
  > 此时客户端回退至旧的 `daily-cloudcode-pa` 默认策略，失去服务端的优化特性。

### 2. 服务端与上下文因素（理解机制）
- **长思维链前摇**：`High Thinking Effort` 下模型会先推理并产生数千字思考 Token，在输出第一段可见内容前需要数秒思考时间。
- **长上下文预填充**：会话进行到较长轮次（例如达到 8 万 ~ 20 万 Token）时，注意力计算开销上升。

---

## 流程二：自动化一键诊断工具

运行本技能内置的诊断脚本，自动分析当前 AGY 状态、网络连通性及 DNS 模式：

```bash
~/.gemini/skills/agy-aicode-optimizer/scripts/diagnose.sh
```

脚本将自动检查：
1. **启动日志**：是否存在 `context deadline exceeded` 降级记录。
2. **握手时延**：`aicode.googleapis.com` 的 TLS/Total 连接时延是否在 1.5s 安全线内。
3. **DNS 状态**：是否处于 Fake-IP 网段或已成功走直连真实 IP 解析。

---

## 流程三：需要优化的 DNS 与代理配置

为了将连接时延压缩在 1.5s 内，避免 AGY 启动时触发回退，需要在代理软件中为 Google 接口配置 **Fake-IP 过滤**与**预解析优化**。

### 1. Clash / Mihomo 配置
在 `dns` 模块下的 `fake-ip-filter` 中加入相关域名，使其不分配 Fake-IP（避免额外的 TUN 劫持和反查时延）：

```yaml
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-filter:
    - 'aicode.googleapis.com'
    - 'daily-cloudcode-pa.googleapis.com'
    - '*.googleapis.com'
```

### 2. 分流规则推荐
确保上述域名走稳定低延迟的代理节点（如美区优质节点），避免触发多次节点跳转与延迟震荡：

```yaml
rules:
  - DOMAIN,aicode.googleapis.com,PROXY
  - DOMAIN-SUFFIX,googleapis.com,PROXY
```

---

## 流程四：优化前后效果对比验证

以当前排查与诊断的实际交互会话（会话 ID `0922aa24-1a4a-444d-a943-b68f4c1b52b3`，包含全套排查过程、长思维模型交互与多次工具调用）为例：

| 评估维度 | 优化前 (DNS 未调优 / Fake-IP 劫持) | 优化后 (加入过滤直连解析 / 握手缩减) |
| :--- | :--- | :--- |
| **启动 FetchConfig 状态** | ❌ 报错 `context deadline exceeded`，降级为默认 flags | ✅ 成功 `serving AICode FetchConfig flags after 1.312s` |
| **API 握手总时延 (TLS + HTTP)** | ~1.5s ~ 2.1s (易偶发超时降级) | **0.97s** (稳定进入安全阈值以内) |
| **DNS 解析方式** | 虚假 IP 网段 (`198.18.0.x`) | 真实 Google IP (`172.217.x.x`) |
| **Gemini 3.8 Flash (High) 交互耗时** | 握手卡顿，等待超时回退，波动明显 | **0~1 秒** 极速完成生成响应（多次步骤 0.0s~1.0s 即时返回） |

> [!TIP]
> 修改完代理配置后，需**完全退出并重启 AGY CLI**，才能使 AGY 在新进程启动时以优化后的网络链路完成首次 FetchConfig 握手。
