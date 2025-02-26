#!/bin/bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="$SCRIPT_DIR/.."
STATE_DIR="$ROOT_DIR/scripts/state"
VALIDATION_STATUS_FILE="$STATE_DIR/validation_status.json"

JSON_FILE="$ROOT_DIR/dnsselect/${CURRENT_COUNTRY}.json"

mkdir -p "$STATE_DIR"

COUNTRIES=($(grep -vE '^\s*(#|$)' "$SCRIPT_DIR/country_codes.txt"))
TOTAL=${#COUNTRIES[@]}

if [[ -f "$VALIDATION_STATUS_FILE" ]]; then
  if [[ ! -s "$VALIDATION_STATUS_FILE" ]]; then
    CURRENT_INDEX=0
    validation_data="[]"
  else
    validation_data=$(cat "$VALIDATION_STATUS_FILE")
    LAST_INDEX=$(jq -r '.[-1].index' <<< "$validation_data")
    CURRENT_INDEX=$(( (LAST_INDEX + 1) % TOTAL ))
  fi
else
  CURRENT_INDEX=0
  validation_data="[]"
fi

CURRENT_COUNTRY=${COUNTRIES[$CURRENT_INDEX]}
JSON_FILE="$ROOT_DIR/dnsselect/${CURRENT_COUNTRY}.json"

echo "今日验证国家: $CURRENT_COUNTRY (进度: $((CURRENT_INDEX + 1))/$TOTAL)"

CURRENT_TIME=$(date --utc +'%Y-%m-%dT%H:%M:%SZ')

if echo "$validation_data" | jq -e ".[] | select(.country_id == \"$CURRENT_COUNTRY\") | .checked_at" | \
   grep -q "$(date --utc --date='1 month ago' +%Y-%m-%d)"; then
  echo "$CURRENT_COUNTRY 最近一个月内已验证过，跳过本次验证。"
  exit 0
fi

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

if verify_ips "$JSON_FILE"; then
  # 更新验证历史
  new_entry=$(jq -n --arg country "$CURRENT_COUNTRY" --arg time "$CURRENT_TIME" --argjson index "$CURRENT_INDEX" \
    '{country_id: $country, checked_at: $time, index: $index}')
  updated_data=$(echo "$validation_data" | jq ". + [$new_entry]")

  echo "$updated_data" > "$VALIDATION_STATUS_FILE"

  echo "验证完成！更新状态至索引: $CURRENT_INDEX"
else
  echo "验证失败，保留上次状态"
fi
