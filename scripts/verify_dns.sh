#!/bin/bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="$SCRIPT_DIR/.."
STATE_FILE="$SCRIPT_DIR/state/verification.json"
DNS_DIR="$ROOT_DIR/dnsselect"
mkdir -p "$DNS_DIR"

# 重定向所有调试输出到 stderr
exec 3>&1
log() { echo "$@" >&3; }

# 增强的 IP 验证逻辑（无标准输出污染）
verify_ip() {
  local ip=$1
  local timeout=3
  local success=0

  # 端口检查（抑制输出）
  if nc -zw 2 "$ip" 53 2>/dev/null; then
    # DNS 解析检查
    if timeout $timeout dig +short @$ip www.google.com | grep -Pq '^\d+\.\d+\.\d+\.\d+$'; then
      success=1
    fi
  else
    # 端口不可用时扫描 /24 段（日志通过 stderr 输出）
    log "扫描 ${ip%.*}.0/24 段..." >&2
    local base_net=$(echo "$ip" | cut -d. -f1-3)
    for i in {1..254}; do
      local test_ip="${base_net}.${i}"
      if timeout 1 nc -zw 1 "$test_ip" 53 2>/dev/null; then
        log "发现可用IP: $test_ip" >&2
        success=1
        break
      fi
    done
  fi

  return $success
}

process_entry() {
  local entry=$1
  local ip=$(jq -r '.ip' <<< "$entry")
  local current_time=$(date --utc +'%Y-%m-%dT%H:%M:%SZ')

  if verify_ip "$ip"; then
    jq --arg time "$current_time" '.available = true | .checked_at = $time' <<< "$entry"
  else
    jq --arg time "$current_time" '.available = false | .checked_at = $time' <<< "$entry"
  fi
}

main() {
  local country=$(jq -r '.last_country' "$STATE_FILE" 2>/dev/null || echo "")
  [[ -z "$country" ]] && country="af"  # 示例默认值

  local json_file="$DNS_DIR/${country}.json"
  [[ ! -f "$json_file" ]] && { log "文件不存在: $json_file"; exit 1; }

  tmp_file=$(mktemp)
  jq -c '.[]' "$json_file" | while read -r entry; do
    process_entry "$entry"
  done | jq -s '.' > "$tmp_file"

  if jq empty "$tmp_file"; then
    mv "$tmp_file" "$json_file"
    log "验证完成：$country"
  else
    log "生成的JSON无效，放弃更新"
    rm "$tmp_file"
  fi
}

# 执行入口
main "$@"
