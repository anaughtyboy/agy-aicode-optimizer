#!/usr/bin/env bash
set -euo pipefail

echo "========================================================"
echo "    AGY & AICode 路由连通性与性能全自动诊断工具"
echo "========================================================"
echo ""

# 1. 查找最新 CLI 日志
LATEST_LOG=$(ls -t ~/.gemini/antigravity-cli/log/cli-*.log 2>/dev/null | head -1 || true)

echo "▶ [步骤 1/3] 检查 AGY 最近一次启动时的 AICode 路由状态..."
if [ -n "$LATEST_LOG" ] && [ -f "$LATEST_LOG" ]; then
    echo "  正在分析日志: $(basename "$LATEST_LOG")"
    
    TIMEOUT_MATCH=$(grep -i "context deadline exceeded" "$LATEST_LOG" | grep -i "fetchConfig" || true)
    SUCCESS_MATCH=$(grep -i "CCPA routed this account to AICode; serving AICode FetchConfig flags" "$LATEST_LOG" || true)
    
    if [ -n "$TIMEOUT_MATCH" ]; then
        echo "  ❌ 【诊断异常】：存在 FetchConfig 超时 (context deadline exceeded)！"
        echo "     日志内容: $TIMEOUT_MATCH"
        echo "     说明: AGY 启动拉取实验特性超时，已自动回退降级到 CCPA 默认规则。"
    elif [ -n "$SUCCESS_MATCH" ]; then
        echo "  ✅ 【状态优秀】：AICode FetchConfig 已成功拉取并激活！"
        echo "     日志内容: $SUCCESS_MATCH"
    else
        echo "  ℹ️  未在当前日志中捕获到明显的 FetchConfig 状态变更（可能为长期未重启进程）。"
    fi
else
    echo "  ⚠️ 未找到 cli 日志文件。"
fi

echo ""
echo "▶ [步骤 2/3] 测试 aicode.googleapis.com 当前网络握手与 DNS 延迟..."
ENDPOINT="https://aicode.googleapis.com/v1alpha:fetchConfig"
LATENCY_RESULT=$(curl -s -o /dev/null -w "HTTP %{http_code} | DNS: %{time_namelookup}s | Connect: %{time_connect}s | TLS: %{time_appconnect}s | Total: %{time_total}s\n" "$ENDPOINT" 2>&1 || true)
echo "  探测结果: $LATENCY_RESULT"

# 提取总耗时
TOTAL_TIME=$(echo "$LATENCY_RESULT" | awk -F 'Total: ' '{print $2}' | sed 's/s//' | tr -d ' ')
if [ -n "$TOTAL_TIME" ]; then
    IS_SLOW=$(python3 -c "print(1 if float('$TOTAL_TIME') > 1.4 else 0)" 2>/dev/null || echo 0)
    if [ "$IS_SLOW" -eq 1 ]; then
        echo "  ⚠️ 当前握手总时延 ($TOTAL_TIME s) 接近或超过了 AGY 内置超时阈值 (~1.5s)！"
        echo "     极易在高并发或冷启动时再次引发超时降级。"
    else
        echo "  ✅ 当前网络时延在安全阈值以内 ($TOTAL_TIME s < 1.5s)。"
    fi
fi

echo ""
echo "▶ [步骤 3/3] 检查代理与 DNS 环境 (Fake-IP / TUN 状态)..."
RESOLVED_IP=$(dig aicode.googleapis.com +short 2>/dev/null || nslookup aicode.googleapis.com 2>/dev/null | grep 'Address' | tail -1 | awk '{print $2}' || true)
echo "  当前域名解析到 IP: $RESOLVED_IP"

if [[ "$RESOLVED_IP" =~ ^198\.18\. ]]; then
    echo "  💡 检测到当前处于 Fake-IP (198.18.0.0/15) 网段。"
    echo "     如果此域名此前发生过握手超时，建议确保该域名在 Clash/Surge 中已配置 fake-ip-filter 绕过解析。"
else
    echo "  ✅ 当前域名已直接解析为真实外部 IP 或直连解析通道。"
fi

echo ""
echo "========================================================"
echo "诊断结束。"
echo "========================================================"
