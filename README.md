# agy-aicode-optimizer

> 🚀 **AGY CLI & Google AICode 路由优化与性能诊断技能包**  
> 专门排查与解决在 Google Antigravity CLI (`agy`) 中使用 Gemini（特别是 High Thinking Effort 模式）响应卡顿、`FetchConfig` 超时降级、DNS/Fake-IP 延迟等问题。

---

## 📖 背景痛点

在使用 Google Antigravity CLI 时，很多开发者遇到了类似的问题：
1. **明明挂了美区节点，为什么模型响应极慢？**
2. **为什么 AGY CLI 启动时会有卡顿与降级感？**
3. **日志中频繁出现 `context deadline exceeded` 报错？**

### 核心根因定位
- **严格超时阈值**：AGY 启动阶段向 `https://aicode.googleapis.com/v1alpha:fetchConfig` 拉取实验配置和 Mendel 路由，内置了 **~1.5 秒的极短超时**。
- **TUN + Fake-IP 额外开销**：Clash/Surge 等代理工具在 TUN + Fake-IP 模式下，冷启动的域名反查与 TLS 握手时延极易超过 1.5 秒，导致日志中抛出：
  ```log
  CCPA routed this account to AICode, but AICode FetchConfig failed, serving CCPA's flags: context deadline exceeded
  ```
  客户端被迫降级回退到旧版 CCPA 规则，失去新后端的优化特性。

---

## ⚡ 优化前后实测效果对比

以实际排查交互会话为例：

| 评估指标 | 优化前 (DNS 未调优 / Fake-IP 劫持) | 优化后 (配置过滤直连解析 / 握手缩减) |
| :--- | :--- | :--- |
| **FetchConfig 启动状态** | ❌ 报错 `context deadline exceeded`，降级为默认 flags | ✅ 成功 `serving AICode FetchConfig flags after 1.312s` |
| **API 握手总时延 (TLS + HTTP)** | ~1.5s ~ 2.1s (易偶发超时降级) | **0.97s** (稳定进入安全阈值以内) |
| **DNS 解析方式** | 虚假 IP 网段 (`198.18.0.x`) | 真实 Google IP (`172.217.x.x`) |
| **Gemini 3.8 Flash (High) 交互** | 握手卡顿，等待超时回退，波动明显 | **0~1 秒** 极速完成生成响应（多次步骤 0.0s~1.0s 即时返回） |

---

## 🛠️ 安装与使用

### 1. 一键安装到 AGY Skills

克隆本仓库到本地 AGY skills 目录即可：

```bash
git clone https://github.com/anaughtyboy/agy-aicode-optimizer.git ~/.gemini/skills/agy-aicode-optimizer
```

### 2. 运行一键诊断脚本

随时在终端运行内置的自动化诊断工具进行体检：

```bash
~/.gemini/skills/agy-aicode-optimizer/scripts/diagnose.sh
```

**诊断脚本自动检查三项指标：**
1. **启动日志检查**：检测最近启动是否发生了 `FetchConfig` 超时降级；
2. **握手时延测试**：测试 `aicode.googleapis.com` 的 TLS/Total 连接耗时是否在 1.5s 安全阈值内；
3. **DNS 模式判断**：检测当前域名是处于 Fake-IP 网段还是已成功走真实 IP 直连。

---

## 🔧 推荐的代理 / DNS 优化配置

### Clash / Mihomo 配置
在 `dns` 模块下的 `fake-ip-filter` 中加入相关域名，使其绕过 Fake-IP 虚假地址分配：

```yaml
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-filter:
    - 'aicode.googleapis.com'
    - 'daily-cloudcode-pa.googleapis.com'
    - '*.googleapis.com'
```

### 分流规则（Rules）
确保上述域名走低延迟、稳定的节点通道：

```yaml
rules:
  - DOMAIN,aicode.googleapis.com,PROXY
  - DOMAIN-SUFFIX,googleapis.com,PROXY
```

> [!TIP]
> 修改完代理配置后，需要**完全退出并重启一次 AGY CLI**，AGY 即可在新进程中成功在 1.5s 内拉取到最新的 AICode 路由配置。

---

## 📄 License
MIT License
