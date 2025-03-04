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

if [[ -f "$VALIDATION_STATUS_FILE" && -s "$VALIDATION_STATUS_FILE" ]]; then
  validation_data=$(cat "$VALIDATION_STATUS_FILE")
else
  validation_data="[]"
fi

current_index=-1
CURRENT_COUNTRY=""
for ((i=0; i < TOTAL; i++)); do
  country=${COUNTRIES[$i]}
  entry=$(echo "$validation_data" | jq -r ".[] | select(.country_id == \"$country\")")
  
  if [[ -z "$entry" ]]; then
    # 未找到记录，需要验证
    current_index=$i
    CURRENT_COUNTRY="$country"
    break
  else
    last_checked=$(echo "$entry" | jq -r '.checked_at' | sort | tail -n1)
    last_ts=$(date --utc -d "$last_checked" +%s)
    month_ago_ts=$(date --utc -d "1 month ago" +%s)
    if (( last_ts <= month_ago_ts )); then
      # 超过一个月，需要验证
      current_index=$i
      CURRENT_COUNTRY="$country"
      break
    fi
  fi
done

if [[ -z "$CURRENT_COUNTRY" ]]; then
  echo "所有国家均已在有效期内，无需验证。"
  exit 0
fi

JSON_FILE="$ROOT_DIR/dnsselect/${CURRENT_COUNTRY}.json"
echo "今日验证国家: $CURRENT_COUNTRY (进度: $((current_index + 1))/$TOTAL)"

CURRENT_TIME=$(date --utc +'%Y-%m-%dT%H:%M:%SZ')


if echo "$validation_data" | jq -e ".[] | select(.country_id == \"$CURRENT_COUNTRY\") | .checked_at" | \
   grep -q "$(date --utc --date='1 month ago' +%Y-%m-%d)"; then
  echo "$CURRENT_COUNTRY 最近一个月内已验证过，跳过本次验证。"
  exit 0
fi

is_ipv4() {
  local ip=$1
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
  local ip=$1
  [[ "$ip" =~ ^([0-9a-fA-F:]+)$ ]]
}

scan_available_ips() {
  local original_ip=$1
  
  if is_ipv6 "$original_ip"; then
    echo "IPv6 地址 $original_ip，不执行扫段。" >&2
    return 1
  fi
  
  echo "IP $original_ip 不可用，开始扫描同网段..." >&2

  local base_ip=$(cut -d. -f1-3 <<< "$original_ip")
  local current_last=$(cut -d. -f4 <<< "$original_ip")
  
  local generated_ips=()
  for i in {1..254}; do
    [[ $i -ne "$current_last" ]] && generated_ips+=("$base_ip.$i")
  done
  
  local available_ips=$(
    printf "%s\n" "${generated_ips[@]}" \
    | xargs -n1 -P50 -I{} bash -c \
      'timeout 1 nc -z -w 3 {} 53 2>/dev/null && echo {}' 2>/dev/null \
    | sort -u
  )

  [[ -z "$available_ips" ]] && return 1
  echo "$available_ips"
}

verify_ips() {
  local json_file=$1
  [[ ! -f "$json_file" ]] && { echo "文件不存在: $json_file"; return 1; }

  tmp_file="${json_file}.tmp"
  jq -c '.[]' "$json_file" | while read -r entry; do

    local ip_time=$(date --utc +'%Y-%m-%dT%H:%M:%SZ') 

    ip=$(jq -r '.ip' <<< "$entry")
    original_ip=$ip
    available=false
    updated=false

    dig_result=$(timeout 3 dig @$ip www.google.com +short)
    port_result=$(timeout 3 nc -z -w 3 $ip 53 2>/dev/null && echo "open" || echo "closed")

    if [[ "$dig_result" =~ [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]] || [[ "$port_result" == "open" ]]; then
      available=true
    else
      if available_ips=$(scan_available_ips "$ip"); then
        new_ip=$(head -n1 <<< "$available_ips")
        echo "找到 $(wc -l <<< "$available_ips") 个可用IP，替换为 $new_ip" >&2
        ip=$new_ip
        available=true
        updated=true
      else
        echo "未找到可用IP，保持原IP不可用状态" >&2
      fi
    fi

    if [[ "$available" == true && "$updated" == true ]]; then
      entry=$(jq --arg ip "$ip" --arg time "$ip_time" \
        '. | .ip = $ip | .available = true | .checked_at = $time' <<< "$entry")
    else
      entry=$(jq --arg time "$ip_time" \
        '. | .available = '"$available"' | .checked_at = $time' <<< "$entry")
    fi

    echo "$entry"
  done | jq -s '.' > "$tmp_file" && mv "$tmp_file" "$json_file"
}

if verify_ips "$JSON_FILE"; then
  updated_data=$(echo "$validation_data" | jq --arg country "$CURRENT_COUNTRY" --arg time "$CURRENT_TIME" --argjson idx "$current_index" \
    'map(select(.country_id != $country)) + [{"country_id": $country, "checked_at": $time, "index": $idx}]')
  echo "$updated_data" > "$VALIDATION_STATUS_FILE"
  echo "验证完成！更新状态至索引: $current_index"
else
  echo "验证失败，保留上次状态"
  exit 1
fi
