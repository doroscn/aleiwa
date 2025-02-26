#!/bin/bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="$SCRIPT_DIR/.."
STATE_FILE="$SCRIPT_DIR/state/verification.json"
DNS_DIR="$ROOT_DIR/dnsselect"
mkdir -p "$DNS_DIR"

# 加强 JSON 文件校验
validate_json() {
  local file=$1
  if ! jq empty "$file" 2>/dev/null; then
    echo "错误: ${file} 不是有效的 JSON 文件！" >&2
    return 1
  fi
}

# 更安全的状态文件初始化
init_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  if [[ ! -f "$STATE_FILE" ]] || ! jq empty "$STATE_FILE" 2>/dev/null; then
    echo '{"last_updated":"","countries":{}}' > "$STATE_FILE"
  fi
}

# 增强国家选择逻辑
select_country() {
  local today=$(date +%Y-%m-%d)
  for country in "${COUNTRIES[@]}"; do
    # 处理特殊字符转义
    local country_escaped=$(jq -Rn --arg c "$country" '$c | @json' | tr -d '"')
    local next_verify=$(jq -r --arg c "$country_escaped" '.countries[$c].next_verify // "1970-01-01"' "$STATE_FILE")
    if [[ "$today" > "$next_verify" ]]; then
      echo "$country"
      return 0
    fi
  done
  echo ""
}

# 改进的验证流程
verify_ip() {
  local ip=$1
  local timeout=3

  # 增加超时和错误捕获
  if ! nc -zw 2 "$ip" 53 2>/dev/null; then
    echo "扫描 ${ip%.*}.0/24 段..."
    local base_net=$(echo "$ip" | cut -d. -f1-3)
    for i in {1..254}; do
      local test_ip="${base_net}.${i}"
      if timeout 1 nc -zw 1 "$test_ip" 53 2>/dev/null; then
        echo "$test_ip:53 可用"
        return 0
      fi
    done
    return 1
  else
    if timeout $timeout dig +short @$ip www.google.com | grep -qP '^\d+\.\d+\.\d+\.\d+$'; then
      return 0
    else
      return 1
    fi
  fi
}

# 主流程加强容错
main() {
  init_state
  COUNTRIES=($(grep -vE '^\s*(#|$)' "$SCRIPT_DIR/country_codes.txt" | tr '[:upper:]' '[:lower:]'))
  target_country=$(select_country)

  [[ -z "$target_country" ]] && echo "无需验证" && exit 0

  echo "今日验证国家: $target_country"
  JSON_FILE="$DNS_DIR/${target_country}.json"
  
  # 严格校验源文件
  if [[ -f "$JSON_FILE" ]]; then
    validate_json "$JSON_FILE" || exit 1
    tmp_file=$(mktemp)
    
    # 重构数据处理流程
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
    echo "文件不存在: $JSON_FILE"
  fi
}

# 执行入口添加错误捕获
main "$@"
