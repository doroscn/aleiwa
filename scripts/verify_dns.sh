#!/bin/bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="$SCRIPT_DIR/.."
STATE_DIR="$ROOT_DIR/scripts/state"           # 状态目录仍在 scripts/state
JSON_FILE="$ROOT_DIR/dnsselect/${CURRENT_COUNTRY}.json"  # JSON文件路径指向根目录

# 获取国家列表
COUNTRIES=($(grep -vE '^\s*(#|$)' "$SCRIPT_DIR/country_codes.txt"))
TOTAL=${#COUNTRIES[@]}

# 读取上次处理的国家索引
if [[ -f "$LAST_COUNTRY_FILE" ]]; then
  LAST_INDEX=$(cat "$LAST_COUNTRY_FILE")
  CURRENT_INDEX=$(( (LAST_INDEX + 1) % TOTAL ))
else
  CURRENT_INDEX=0
fi

# 获取当前要处理的国家
CURRENT_COUNTRY=${COUNTRIES[$CURRENT_INDEX]}
JSON_FILE="$ROOT_DIR/dnsselect/${CURRENT_COUNTRY}.json"

echo "今日验证国家: $CURRENT_COUNTRY (进度: $((CURRENT_INDEX + 1))/$TOTAL)"
echo "$JSON_FILE"

# 验证函数
verify_ips() {
  local json_file=$1
  [[ ! -f "$json_file" ]] && { echo "文件不存在: $json_file"; return 1; }

  tmp_file="${json_file}.tmp"
  jq -c '.[]' "$json_file" | while read -r entry; do
    ip=$(jq -r '.ip' <<< "$entry")
    
    # 查询DNS可用性（Google+Cloudflare双验证）
    if timeout 3 dig @$ip www.google.com +short | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' && \
       timeout 3 dig @$ip one.one.one.one +short | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
      jq '.available = true' <<< "$entry"
    else
      jq '.available = false' <<< "$entry"
    fi
  done | jq -s '.' > "$tmp_file" && mv "$tmp_file" "$json_file"
}

# 执行验证
if verify_ips "$JSON_FILE"; then
  echo "$CURRENT_INDEX" > "$LAST_COUNTRY_FILE"
  echo "验证完成！更新状态至索引: $CURRENT_INDEX"
else
  echo "验证失败，保留上次状态"
fi
