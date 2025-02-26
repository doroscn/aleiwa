#!/bin/bash
set -eo pipefail

# 配置路径
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="$SCRIPT_DIR/.."
STATE_FILE="$SCRIPT_DIR/state/verification.json"
DNS_DIR="$ROOT_DIR/dnsselect"
mkdir -p "$DNS_DIR"

# 加载国家列表
COUNTRIES=($(grep -vE '^\s*(#|$)' "$SCRIPT_DIR/country_codes.txt" | tr '[:upper:]' '[:lower:]'))

# 初始化或加载状态文件
init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{"last_updated":"","countries":{}}' > "$STATE_FILE"
  fi
  jq -c '.' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# 获取待验证国家
select_country() {
  local today=$(date +%Y-%m-%d)
  for country in "${COUNTRIES[@]}"; do
    local next_verify=$(jq -r ".countries.\"$country\".next_verify // \"1970-01-01\"" "$STATE_FILE")
    if [[ "$today" > "$next_verify" ]]; then
      echo "$country"
      return 0
    fi
  done
  echo ""
}

# 核心验证函数
verify_ip() {
  local ip=$1
  local timeout=3

  # 检查53端口可用性（TCP/UDP）
  if ! nc -zvw2 "$ip" 53 &>/dev/null; then
    # 端口不可用 → 扫描/24段
    echo "扫描 ${ip%.*}.0/24 段..."
    local base_net=$(echo "$ip" | cut -d. -f1-3)
    for i in {1..254}; do
      local test_ip="${base_net}.${i}"
      if nc -zvw1 "$test_ip" 53 &>/dev/null; then
        echo "$test_ip:53 可用"
        return 0
      fi
    done
    return 1
  else
    # 端口可用 → 验证DNS解析
    if timeout $timeout dig @$ip www.google.com +short | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
      return 0
    else
      return 1
    fi
  fi
}

# 更新状态文件
update_state() {
  local country=$1
  local today=$(date +%Y-%m-%d)
  local next_date=$(date -d "$today +30 days" +%Y-%m-%d)
  
  jq \
    --arg country "$country" \
    --arg today "$today" \
    --arg next "$next_date" \
    '.last_updated = $today |
     .countries[$country] = {
       "last_verified": $today,
       "next_verify": $next
     }' "$STATE_FILE" > "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# 主流程
init_state
target_country=$(select_country)

if [[ -z "$target_country" ]]; then
  echo "所有国家均在有效期内，无需验证"
  exit 0
fi

echo "今日验证国家: $target_country"
JSON_FILE="$DNS_DIR/${target_country}.json"

# 执行验证
if [[ -f "$JSON_FILE" ]]; then
  tmp_file="${JSON_FILE}.tmp"
  jq -c '.[]' "$JSON_FILE" | while read -r entry; do
    ip=$(jq -r '.ip' <<< "$entry")
    if verify_ip "$ip"; then
      jq '.available = true' <<< "$entry"
    else
      jq '.available = false' <<< "$entry"
    fi
  done | jq -s '.' > "$tmp_file" && mv "$tmp_file" "$JSON_FILE"
  
  update_state "$target_country"
else
  echo "警告：${target_country}.json 不存在"
fi
