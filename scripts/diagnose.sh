#!/usr/bin/env bash
set -euo pipefail

# 强制 C Locale，防止 awk/curl 小数点受系统语言环境影响变为逗号
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_SCRIPT="$SCRIPT_DIR/probe_proxy_api.sh"

OUTPUT_JSON=0
if [[ "${1:-}" == "--json" ]]; then
    OUTPUT_JSON=1
fi

log_info() {
    if [[ "$OUTPUT_JSON" -eq 0 ]]; then
        echo "$*"
    fi
}

# 检查核心依赖
if ! command -v curl >/dev/null 2>&1; then
    echo "Error: 'curl' is required but not installed." >&2
    exit 1
fi

log_info "========================================================"
log_info "    AGY & AICode 路由连通性与性能全自动诊断工具 v2.5"
log_info "========================================================"

# --- [步骤 1/4] 日志分析（扫描最近 3 个日志，按最后一次状态裁决） ---
LOG_DIR="${AGY_LOG_DIR:-$HOME/.gemini/antigravity-cli/log}"
LOG_STATUS="unknown"
LOG_DETAIL=""
LOG_FILE_USED=""

if [[ -d "$LOG_DIR" ]]; then
    # 安全获取最近 3 个日志文件
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        LAST_EVENT=$(grep -iE "(context deadline exceeded.*fetchConfig|serving AICode FetchConfig flags)" "$file" | tail -n 1 || true)
        if [[ -n "$LAST_EVENT" ]]; then
            LOG_FILE_USED=$(basename "$file")
            LOG_DETAIL="$LAST_EVENT"
            if echo "$LAST_EVENT" | grep -qi "context deadline exceeded"; then
                LOG_STATUS="degraded"
            else
                LOG_STATUS="healthy"
            fi
            break
        fi
    done < <(ls -t "$LOG_DIR"/cli-*.log 2>/dev/null | head -n 3 || true)
fi

log_info ""
log_info "▶ [步骤 1/4] AGY 启动路由状态 ($LOG_FILE_USED)"
case "$LOG_STATUS" in
    degraded) log_info "  ❌ 【异常】最近一次 FetchConfig 超时降级: $LOG_DETAIL" ;;
    healthy)  log_info "  ✅ 【优秀】AICode FetchConfig 已激活: $LOG_DETAIL" ;;
    *)        log_info "  ℹ️  未在最近 3 个日志中捕获到 FetchConfig 事件。" ;;
esac

# --- [步骤 2/4] 网络握手探测（带超时熔断与 HTTP 状态校验） ---
ENDPOINT="https://aicode.googleapis.com/v1alpha:fetchConfig"
PROXY_ENV="${HTTPS_PROXY:-${https_proxy:-${ALL_PROXY:-${all_proxy:-none}}}}"

# 严格格式输出，加入 5 秒总超时和 3 秒连接超时
METRICS=$(curl -sS -o /dev/null --connect-timeout 3 --max-time 5 \
    -w "%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_total}" \
    "$ENDPOINT" 2>/dev/null || echo "000|0|0|0|0")

IFS='|' read -r HTTP_CODE T_DNS T_CONN T_TLS T_TOTAL <<< "$METRICS"

NET_STATUS="error"
if [[ "$HTTP_CODE" == "000" ]] || [[ -z "$HTTP_CODE" ]]; then
    NET_STATUS="unreachable"
else
    # 使用 POSIX awk 替代 python3 进行浮点比较
    IS_SLOW=$(awk -v t="$T_TOTAL" 'BEGIN { print (t + 0 > 1.4) ? 1 : 0 }')
    if [[ "$IS_SLOW" -eq 1 ]]; then
        NET_STATUS="slow"
    else
        NET_STATUS="ok"
    fi
fi

log_info ""
log_info "▶ [步骤 2/4] 握手与时延探测 (终端代理环境: $PROXY_ENV)"
log_info "  结果: HTTP $HTTP_CODE | DNS: ${T_DNS}s | Connect: ${T_CONN}s | TLS: ${T_TLS}s | Total: ${T_TOTAL}s"
case "$NET_STATUS" in
    unreachable) log_info "  ❌ 【连接失败】无法触达 $ENDPOINT (HTTP 000，请检查代理节点或网络连通性)。" ;;
    slow)        log_info "  ⚠️ 【时延过高】总耗时 ${T_TOTAL}s 接近或超过 1.5s 安全阈值，极易触发降级。" ;;
    ok)          log_info "  ✅ 【时延健康】总耗时 ${T_TOTAL}s (< 1.4s 安全线)。" ;;
esac

# --- [步骤 3/4] 跨平台 DNS 与 Fake-IP 归因 ---
resolve_ips() {
    local host="$1"
    if command -v dig >/dev/null 2>&1; then
        dig +short "$host" A "$host" AAAA 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' || true
    elif command -v getent >/dev/null 2>&1; then
        getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u || true
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup "$host" 2>/dev/null | awk '/^Address: / {print $2}' || true
    fi
}

RESOLVED_IPS=$(resolve_ips "aicode.googleapis.com" | tr '\n' ' ' | sed 's/ $//')
DNS_MODE="unknown"

if [[ -z "$RESOLVED_IPS" ]]; then
    DNS_MODE="failed"
elif echo "$RESOLVED_IPS" | grep -qE '(^| )(198\.1[89]\.|fc00:)'; then
    DNS_MODE="fake-ip"
else
    DNS_MODE="real-ip"
fi

log_info ""
log_info "▶ [步骤 3/4] 系统 DNS 解析状态"
log_info "  解析 IP 列表: ${RESOLVED_IPS:-无}"
case "$DNS_MODE" in
    fake-ip) log_info "  💡 检测到 Fake-IP 网段 (198.18.0.0/15 或 fc00::/18)。" ;;
    real-ip) log_info "  ✅ 已解析为真实 IP（请确保代理已开启 Sniffer 嗅探且上游 DNS 无污染）。" ;;
    failed)  log_info "  ❌ DNS 解析失败，请检查本地 DNS 服务。" ;;
esac

# --- [步骤 4/4] 本地代理控制面白盒透视（只读、静默降级） ---
PROXY_PROBE_JSON='{"status":"unavailable","client":"none","endpoint":"","mode":"unknown","target_domain":"aicode.googleapis.com","matched_rule":"","policy_chain":[],"active_node":{"name":"","type":"","delay_ms":-1},"alternatives":[]}'

log_info ""
log_info "▶ [步骤 4/4] 代理控制面白盒透视 (Clash/Mihomo/Surge)"
if [[ -f "$PROBE_SCRIPT" ]]; then
    if [[ "$OUTPUT_JSON" -eq 1 ]]; then
        PROXY_PROBE_JSON=$(bash "$PROBE_SCRIPT" --json 2>/dev/null || echo "$PROXY_PROBE_JSON")
    else
        bash "$PROBE_SCRIPT" || true
    fi
else
    log_info "  ℹ️  未发现探针脚本 ($PROBE_SCRIPT)，跳过白盒透视。"
fi

# JSON 结构化输出模式（专供 AGY Agent 消费）
if [[ "$OUTPUT_JSON" -eq 1 ]]; then
    cat <<EOF
{
  "log_status": "$LOG_STATUS",
  "log_file": "$LOG_FILE_USED",
  "proxy_env": "$PROXY_ENV",
  "network": {
    "status": "$NET_STATUS",
    "http_code": "$HTTP_CODE",
    "dns_s": $T_DNS,
    "connect_s": $T_CONN,
    "tls_s": $T_TLS,
    "total_s": $T_TOTAL
  },
  "dns": {
    "mode": "$DNS_MODE",
    "ips": "$RESOLVED_IPS"
  },
  "proxy_control_plane": $PROXY_PROBE_JSON
}
EOF
fi
