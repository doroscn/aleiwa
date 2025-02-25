#!/bin/bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="$SCRIPT_DIR/.."
OUTPUT_DIR="$ROOT_DIR/dnsselect"
mkdir -p "$OUTPUT_DIR"
COUNTRY_FILE="$SCRIPT_DIR/country_codes.txt"

THREADS=5  # 并发下载数

# 并发控制初始化
tmp_fifofile=$(mktemp -u)
mkfifo "$tmp_fifofile"
exec 6<>"$tmp_fifofile"
rm -f "$tmp_fifofile"

for ((i=0; i<THREADS; i++)); do
  echo >&6
done

# 下载函数
download_country() {
  local country=$1
  echo "下载国家: $country"
  curl -sSf --max-time 20 --retry 2 \
    "http://public-dns.info/nameserver/${country}.json" \
    -o "${OUTPUT_DIR}/${country}.json" || echo "[ERROR] 下载失败: $country" >&2
}

# 主循环
while IFS= read -r country; do
  [[ -z "$country" || "$country" == \#* ]] && continue
  read -u6
  { download_country "$country"; echo >&6; } &
done < <(grep -vE '^\s*(#|$)' "$COUNTRY_FILE")

wait
exec 6>&-
echo "所有国家数据下载完成！保存至 $OUTPUT_DIR"
