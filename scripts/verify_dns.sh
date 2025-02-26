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

# JSON 处理流程
process_entry() {
  local entry=$1
  local ip=$(jq -r '.ip' <<< "$entry")
  local current_time=$(date --utc +'%Y-%m-%dT%H:%M:%SZ')

  # 尝试验证当前的 IP
  if verify_ip "$ip"; then
    # 如果当前 IP 可用，更新 entry 的验证状态
    jq --arg time "$current_time" '.available = true | .checked_at = $time' <<< "$entry"
  else
    # 如果当前 IP 不可用，开始扫描 /24 网络段中的其他 IP
    local base_net=$(echo "$ip" | cut -d. -f1-3)
    local new_ip=""
    
    for i in {1..254}; do
      local test_ip="${base_net}.${i}"
      
      # 如果发现新的可用 IP 地址，替换当前 IP 地址
      if verify_ip "$test_ip"; then
        new_ip="$test_ip"
        log "替换原有IP：$ip 为新可用IP：$new_ip"
        break
      fi
    done
    
    # 如果找到了新的可用 IP 地址，更新 entry
    if [[ -n "$new_ip" ]]; then
      jq --arg new_ip "$new_ip" --arg time "$current_time" \
        '.ip = $new_ip | .available = true | .checked_at = $time' <<< "$entry"
    else
      jq --arg time "$current_time" '.available = false | .checked_at = $time' <<< "$entry"
    fi
  fi
}

# 主流程
main() {
  local country=$(jq -r '.last_country' "$STATE_FILE" 2>/dev/null || echo "")
  [[ -z "$country" ]] && country="af"  # 示例默认值

  local json_file="$DNS_DIR/${country}.json"
  [[ ! -f "$json_file" ]] && { log "文件不存在: $json_file"; exit 1; }

  # 获取当前时间戳
  local current_time=$(date --utc +'%Y-%m-%dT%H:%M:%SZ')
  local last_verified=$(jq -r ".\"$country\".last_verified" "$STATE_FILE" 2>/dev/null)
  [[ -n "$last_verified" && $(date -d "$last_verified" +%s) -gt $(date -d '1 month ago' +%s) ]] && {
    log "$country 国家最近一个月内已验证，跳过验证"
    return 0
  }

  # 使用临时文件保证数据完整性
  tmp_file=$(mktemp)

  # 存储扫描过的 /24 网段，避免重复扫描
  declare -A scanned_networks

  jq -c '.[]' "$json_file" | while read -r entry; do
    ip=$(jq -r '.ip' <<< "$entry")
    network=$(echo "$ip" | cut -d. -f1-3)  # 提取 /24 网络段

    # 如果该 /24 网络段已经扫描过，跳过
    if [[ -n "${scanned_networks[$network]}" ]]; then
      continue
    fi

    # 如果是新网络段，进行验证并记录该段已扫描
    process_entry "$entry" && scanned_networks[$network]=1
  done | jq -s '.' > "$tmp_file"

  # 验证并替换原文件
  if jq empty "$tmp_file"; then
    mv "$tmp_file" "$json_file"
    jq --arg country "$country" --arg time "$current_time" \
      '. + {($country): {"last_verified": $time}}' "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    log "验证完成：$country"
  else
    log "生成的JSON无效，放弃更新"
    rm "$tmp_file"
  fi
}

# 执行入口
main "$@"
