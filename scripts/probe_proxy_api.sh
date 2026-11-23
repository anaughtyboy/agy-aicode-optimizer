#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

OUTPUT_JSON=0
TARGET_DOMAIN="aicode.googleapis.com"

for arg in "$@"; do
    case "$arg" in
        --json) OUTPUT_JSON=1 ;;
        --domain=*) TARGET_DOMAIN="${arg#*=}" ;;
    esac
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 默认降级输出结构
emit_fallback_json() {
    local status="$1"
    local client="${2:-none}"
    local endpoint="${3:-}"
    cat <<EOF
{
  "status": "$status",
  "client": "$client",
  "endpoint": "$endpoint",
  "mode": "unknown",
  "target_domain": "$TARGET_DOMAIN",
  "matched_rule": "",
  "policy_chain": [],
  "active_node": {
    "name": "",
    "type": "",
    "delay_ms": -1
  },
  "alternatives": []
}
EOF
}

emit_text_from_json() {
    local json_file="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$json_file" <<'PY'
import json, sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)

st = d.get("status", "unavailable")
client = d.get("client", "none")
ep = d.get("endpoint", "")

if st == "unavailable":
    print("  ℹ️  未检测到开放的本地代理控制面 API（已静默降级，仅使用黑盒诊断）。")
elif st == "unauthorized":
    hint = "CLASH_SECRET / MIHOMO_SECRET" if client in ("clash", "mihomo") else "SURGE_API_KEY"
    print(f"  🔒 检测到 {client} 控制面 ({ep})，但鉴权失败 (401/403)。")
    print(f"     如需白盒透视，请导出环境变量 {hint} 后重试。")
elif st == "parser_unavailable":
    print(f"  ⚠️  检测到 {client} 控制面 ({ep})，但系统缺少 python3，跳过深度规则解析。")
else:
    print(f"  ✅ 已连接控制面: {client} ({ep}) | 运行模式: {d.get('mode', 'unknown')}")
    print(f"  📌 命中规则: {d.get('matched_rule') or '未匹配/未知'}")
    chain = d.get("policy_chain") or []
    if chain:
        print(f"  🔀 策略链路: {' -> '.join(chain)}")
    node = d.get("active_node") or {}
    delay = node.get("delay_ms", -1)
    delay_str = f"{delay}ms" if isinstance(delay, (int, float)) and delay > 0 else "无测速缓存"
    if node.get("name"):
        print(f"  🌐 物理节点: {node['name']} [{node.get('type') or 'unknown'}] (缓存延迟: {delay_str})")
    alts = d.get("alternatives") or []
    if alts:
        alt_str = ", ".join(f"{a['name']} ({a['delay_ms']}ms)" for a in alts)
        print(f"  💡 同组低延迟备选: {alt_str}")
PY
    else
        echo "  ℹ️  控制面探针已完成（缺少 python3，原始状态请使用 --json 查看）。"
    fi
}

# 核心依赖检查
if ! command -v curl >/dev/null 2>&1; then
    JSON_OUT="$TMP_DIR/out.json"
    emit_fallback_json "unavailable" "none" "" > "$JSON_OUT"
    if [[ "$OUTPUT_JSON" -eq 1 ]]; then
        cat "$JSON_OUT"
    else
        emit_text_from_json "$JSON_OUT"
    fi
    exit 0
fi

# 通用本地 GET 封装（强制绕过终端代理环境变量，1s 连接超时，2s 总超时）
local_get() {
    local url="$1"
    local auth_header="${2:-}"
    local out_file="$3"
    local http_code
    if [[ -n "$auth_header" ]]; then
        http_code=$(curl --noproxy '*' -sS --connect-timeout 1 --max-time 2 \
            -H "$auth_header" -o "$out_file" -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    else
        http_code=$(curl --noproxy '*' -sS --connect-timeout 1 --max-time 2 \
            -o "$out_file" -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    fi
    echo "$http_code"
}

DETECTED_CLIENT="none"
DETECTED_EP=""
AUTH_STATUS="none"
CLASH_SECRET_VAL="${MIHOMO_SECRET:-${CLASH_SECRET:-}}"
SURGE_KEY_VAL="${SURGE_API_KEY:-}"

# 1. 自动发现 Clash / Mihomo 控制面
CLASH_CANDIDATES=()
[[ -n "${MIHOMO_API_URL:-}" ]] && CLASH_CANDIDATES+=("${MIHOMO_API_URL%/}")
[[ -n "${CLASH_API_URL:-}" ]] && CLASH_CANDIDATES+=("${CLASH_API_URL%/}")
CLASH_CANDIDATES+=("http://127.0.0.1:9090" "http://127.0.0.1:9097" "http://127.0.0.1:9091")

CLASH_HDR=""
[[ -n "$CLASH_SECRET_VAL" ]] && CLASH_HDR="Authorization: Bearer $CLASH_SECRET_VAL"

for ep in "${CLASH_CANDIDATES[@]}"; do
    code=$(local_get "$ep/version" "$CLASH_HDR" "$TMP_DIR/version.json")
    if [[ "$code" == "200" ]]; then
        DETECTED_EP="$ep"
        if grep -qiE '"meta"[[:space:]]*:[[:space:]]*true|mihomo' "$TMP_DIR/version.json" 2>/dev/null; then
            DETECTED_CLIENT="mihomo"
        else
            DETECTED_CLIENT="clash"
        fi
        AUTH_STATUS="ok"
        break
    elif [[ "$code" == "401" || "$code" == "403" ]]; then
        DETECTED_EP="$ep"
        DETECTED_CLIENT="clash"
        AUTH_STATUS="unauthorized"
        break
    fi
done

# 2. 若未发现 Clash/Mihomo，则探测 Surge HTTP API
if [[ "$DETECTED_CLIENT" == "none" ]]; then
    SURGE_CANDIDATES=()
    [[ -n "${SURGE_API_URL:-}" ]] && SURGE_CANDIDATES+=("${SURGE_API_URL%/}")
    SURGE_CANDIDATES+=("http://127.0.0.1:6171" "http://127.0.0.1:6170")

    SURGE_HDR=""
    [[ -n "$SURGE_KEY_VAL" ]] && SURGE_HDR="X-Key: $SURGE_KEY_VAL"

    for ep in "${SURGE_CANDIDATES[@]}"; do
        code=$(local_get "$ep/v1/outbound" "$SURGE_HDR" "$TMP_DIR/surge_outbound.json")
        if [[ "$code" == "200" ]]; then
            DETECTED_EP="$ep"
            DETECTED_CLIENT="surge"
            AUTH_STATUS="ok"
            break
        elif [[ "$code" == "401" || "$code" == "403" ]]; then
            DETECTED_EP="$ep"
            DETECTED_CLIENT="surge"
            AUTH_STATUS="unauthorized"
            break
        fi
    done
fi

JSON_OUT="$TMP_DIR/out.json"

# 3. 降级分支处理
if [[ "$DETECTED_CLIENT" == "none" ]]; then
    emit_fallback_json "unavailable" "none" "" > "$JSON_OUT"
elif [[ "$AUTH_STATUS" == "unauthorized" ]]; then
    emit_fallback_json "unauthorized" "$DETECTED_CLIENT" "$DETECTED_EP" > "$JSON_OUT"
elif ! command -v python3 >/dev/null 2>&1; then
    emit_fallback_json "parser_unavailable" "$DETECTED_CLIENT" "$DETECTED_EP" > "$JSON_OUT"
else
    # 4. 深度只读拉取与解析
    if [[ "$DETECTED_CLIENT" == "clash" || "$DETECTED_CLIENT" == "mihomo" ]]; then
        local_get "$DETECTED_EP/configs" "$CLASH_HDR" "$TMP_DIR/configs.json" >/dev/null
        local_get "$DETECTED_EP/rules"   "$CLASH_HDR" "$TMP_DIR/rules.json"   >/dev/null
        local_get "$DETECTED_EP/proxies" "$CLASH_HDR" "$TMP_DIR/proxies.json" >/dev/null

        python3 - "$DETECTED_CLIENT" "$DETECTED_EP" "$TARGET_DOMAIN" \
            "$TMP_DIR/configs.json" "$TMP_DIR/rules.json" "$TMP_DIR/proxies.json" > "$JSON_OUT" <<'PY'
import json, sys

client, endpoint, domain, cfg_p, rules_p, proxies_p = sys.argv[1:7]

def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

cfg = load_json(cfg_p)
rules_data = load_json(rules_p)
proxies_data = load_json(proxies_p).get("proxies", {})

mode = str(cfg.get("mode", "rule")).lower()
matched_rule = ""
entry_policy = ""

if mode == "direct":
    matched_rule = "MODE:DIRECT"
    entry_policy = "DIRECT"
elif mode == "global":
    matched_rule = "MODE:GLOBAL"
    entry_policy = "GLOBAL"
else:
    d_lower = domain.lower()
    for r in rules_data.get("rules", []):
        rtype = str(r.get("type", "")).upper()
        payload = str(r.get("payload", "")).lower()
        proxy = str(r.get("proxy", ""))
        hit = False
        if rtype == "DOMAIN" and d_lower == payload:
            hit = True
        elif rtype == "DOMAIN-SUFFIX" and (d_lower == payload or d_lower.endswith("." + payload)):
            hit = True
        elif rtype == "DOMAIN-KEYWORD" and payload and payload in d_lower:
            hit = True
        elif rtype in ("MATCH", "FINAL"):
            hit = True
        if hit:
            matched_rule = f"{rtype},{r.get('payload', '')},{proxy}" if r.get("payload") else f"{rtype},{proxy}"
            entry_policy = proxy
            break

# 递归追踪策略链直至物理节点
chain = []
visited = set()
curr = entry_policy
parent_group = None

while curr and curr not in visited:
    visited.add(curr)
    chain.append(curr)
    info = proxies_data.get(curr)
    if not isinstance(info, dict):
        break
    nxt = info.get("now")
    if nxt and nxt != curr:
        parent_group = curr
        curr = nxt
    else:
        break

def get_last_delay(node_info):
    hist = node_info.get("history") if isinstance(node_info, dict) else None
    if isinstance(hist, list) and hist:
        for item in reversed(hist):
            d = item.get("delay", 0)
            if isinstance(d, (int, float)) and d > 0:
                return int(d)
    return -1

leaf_name = chain[-1] if chain else ""
leaf_info = proxies_data.get(leaf_name, {})
active_delay = get_last_delay(leaf_info)

# 从父策略组筛选同组低延迟备选节点（Top 3）
alternatives = []
if parent_group and parent_group in proxies_data:
    members = proxies_data[parent_group].get("all", [])
    skip_types = {"Selector", "URLTest", "Fallback", "LoadBalance", "Direct", "Reject", "Compatible", "Pass"}
    candidates = []
    for m in members:
        if m == leaf_name or m in ("DIRECT", "REJECT"):
            continue
        minfo = proxies_data.get(m, {})
        if minfo.get("type") in skip_types:
            continue
        mdelay = get_last_delay(minfo)
        if mdelay > 0:
            candidates.append({"name": m, "delay_ms": mdelay})
    candidates.sort(key=lambda x: x["delay_ms"])
    if active_delay > 0:
        better = [c for c in candidates if c["delay_ms"] < active_delay]
        alternatives = better[:3] if better else candidates[:3]
    else:
        alternatives = candidates[:3]

out = {
    "status": "ok",
    "client": client,
    "endpoint": endpoint,
    "mode": mode,
    "target_domain": domain,
    "matched_rule": matched_rule,
    "policy_chain": chain,
    "active_node": {
        "name": leaf_name,
        "type": str(leaf_info.get("type", "")),
        "delay_ms": active_delay
    },
    "alternatives": alternatives
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
    elif [[ "$DETECTED_CLIENT" == "surge" ]]; then
        local_get "$DETECTED_EP/v1/requests/recent" "$SURGE_HDR" "$TMP_DIR/surge_req.json" >/dev/null

        python3 - "$DETECTED_CLIENT" "$DETECTED_EP" "$TARGET_DOMAIN" \
            "$TMP_DIR/surge_outbound.json" "$TMP_DIR/surge_req.json" > "$JSON_OUT" <<'PY'
import json, sys

client, endpoint, domain, out_p, req_p = sys.argv[1:6]

def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

outbound = load_json(out_p)
reqs = load_json(req_p).get("requests", [])

mode = str(outbound.get("mode", "unknown"))
matched_rule = ""
policy_name = ""
chain = []

# 从最近请求中逆序查找目标域名的真实命中记录
for r in reqs:
    url = str(r.get("URL", ""))
    if domain.lower() in url.lower():
        matched_rule = str(r.get("rule", ""))
        policy_name = str(r.get("policyName", ""))
        if policy_name:
            chain = [policy_name]
        break

out = {
    "status": "ok",
    "client": client,
    "endpoint": endpoint,
    "mode": mode,
    "target_domain": domain,
    "matched_rule": matched_rule,
    "policy_chain": chain,
    "active_node": {
        "name": policy_name,
        "type": "SurgePolicy",
        "delay_ms": -1
    },
    "alternatives": []
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
    fi
fi

if [[ "$OUTPUT_JSON" -eq 1 ]]; then
    cat "$JSON_OUT"
else
    emit_text_from_json "$JSON_OUT"
fi
