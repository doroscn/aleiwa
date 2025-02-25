#!/bin/bash
set -e  # 遇到错误立即退出

# 初始化目录
SRC_FILE="$PWD/scripts/country_codes.txt"  # 国家代码文件路径
OUTPUT_DIR="$PWD/dnsselect"
mkdir -p "$OUTPUT_DIR"

# 并发控制配置
THREADS=10
tmp_fifofile="/tmp/$$.fifo"
mkfifo $tmp_fifofile
exec 6<>$tmp_fifofile
rm -f $tmp_fifofile

for ((i=0; i<$THREADS; i++)); do
  echo
done >&6

# 主处理函数
process_country() {
  local country=$1
  local json_file="${OUTPUT_DIR}/${country}.json"
  
  # 下载原始数据
  curl -sSf "http://public-dns.info/nameserver/${country}.json" -o "$json_file" || {
    echo "Failed to download $country" >&2
    return 1
  }

  # 验证DNS可用性
  tmp_file="${json_file}.tmp"
  jq -c '.[]' "$json_file" | while read -r entry; do
    ip=$(jq -r '.ip' <<< "$entry")
    if dig @$ip www.google.com +short +time=3 +tries=2 | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
      jq '.available = true' <<< "$entry"
    else
      jq '.available = false' <<< "$entry"
    fi
  done | jq -s '.' > "$tmp_file" && mv "$tmp_file" "$json_file"
}

# 读取国家代码并处理
while IFS= read -r country; do
  read -u6
  {
    process_country "$country"
    echo >&6
  } &
done < "$SRC_FILE"

wait
exec 6>&-
echo "处理完成！有效DNS已标记"
