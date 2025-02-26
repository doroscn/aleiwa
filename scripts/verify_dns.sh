#!/bin/bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="$SCRIPT_DIR/.."
STATE_DIR="$ROOT_DIR/scripts/state"
VERIFICATION_FILE="$STATE_DIR/verification.json"  # JSON格式的验证历史记录文件
JSON_FILE="$ROOT_DIR/dnsselect/${CURRENT_COUNTRY}.json"  # JSON文件路径

mkdir -p "$STATE_DIR"

# 如果 verification.json 文件不存在，则初始化
if [[ ! -f "$VERIFICATION_FILE" ]]; then
  echo '{"last_country": 0, "validation_history": []}' > "$VERIFICATION_FILE"
fi

# 读取 verification.json 文件
VERIFICATION_DATA=$(cat "$VERIFICATION_FILE")
LAST_INDEX=$(echo "$VERIFICATION_DATA" | jq -r '.last_country')
VALIDATION_HISTORY=$(echo "$VERIFICATION_DATA" | jq -r '.validation_history')

# 获取国家列表
COUNTRIES=($(grep -vE '^\s*(#|$)' "$SCRIPT_DIR/country_codes.txt"))
TOTAL=${#COUNTRIES[@]}

# 计算当前要处理的国家
CURRENT_INDEX=$(( (LAST_INDEX + 1) % TOTAL ))
CURRENT_COUNTRY=${COUNTRIES[$CURRENT_INDEX]}
JSON_FILE="$ROOT_DIR/dnsselect/${CURRENT_COUNTRY}.json"

echo "今日验证国家: $CURRENT_COUNTRY (进度: $((CURRENT_INDEX + 1))/$TOTAL)"

CURRENT_TIME=$(date --utc +'%Y-%m-%dT%H:%M:%SZ')

# 检查是否在最近一个月内验证过
if echo "$VALIDATION_HISTORY" | grep -q "$CURRENT_COUNTRY" && \
   [[ $(date --utc +%s) -lt $(($(date --utc --date="$(echo "$VALIDATION_HISTORY" | grep "$CURRENT_COUNTRY" | cut -d' ' -f2) +1 month" +%s))) ]]; then
  echo "$CURRENT_COUNTRY 最近一个月内已验证过，跳过本次验证。"
  exit 0
fi

# 验证函数
verify_ips() {
  local json_file=$1
  [[ ! -f "$json_file" ]] && { echo "文件不存在: $json_file"; return 1; }

  tmp_file="${json_file}.tmp"
  jq -c '.[]' "$json_file" | while read -r entry; do
    ip=$(jq -r '.ip' <<< "$entry")
    # 使用dig验证
    dig_result=$(timeout 3 dig @$ip www.google.com +short)
    # 使用nc验证53端口
    port_result=$(timeout 3 nc -z -w 3 $ip 53 2>/dev/null && echo "open" || echo "closed")

    if [[ "$dig_result" =~ [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]] || [[ "$port_result" == "open" ]]; then
      # 可用，更新可用性和时间戳
      jq --arg time "$CURRENT_TIME" '. | .available = true | .checked_at = $time' <<< "$entry"
    else
      # 不可用，更新可用性和时间戳
      jq --arg time "$CURRENT_TIME" '. | .available = false | .checked_at = $time' <<< "$entry"
    fi
  done | jq -s '.' > "$tmp_file" && mv "$tmp_file" "$json_file"
}

# 验证并记录历史
if verify_ips "$JSON_FILE"; then
  # 更新验证历史和last_country
  NEW_VALIDATION_HISTORY=$(echo "$VALIDATION_HISTORY" | jq --arg country "$CURRENT_COUNTRY" --arg time "$CURRENT_TIME" \
    '. + [{"country": $country, "time": $time}]')
  jq --argjson history "$NEW_VALIDATION_HISTORY" --arg index "$CURRENT_INDEX" \
    '.last_country = ($index | tonumber) | .validation_history = $history' <<< "{}" > "$VERIFICATION_FILE"

  echo "$CURRENT_INDEX" > "$LAST_COUNTRY_FILE"
  echo "验证完成！更新状态至索引: $CURRENT_INDEX"
else
  echo "验证失败，保留上次状态"
fi
