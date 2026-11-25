#!/bin/bash
set -e

echo "Converting Shift_JIS HTML files in mirror/ to UTF-8..."

# mirror/ 内の .htm と .html をすべて検索して処理
find mirror -type f \( -iname "*.htm" -o -iname "*.html" \) | while IFS= read -r file; do
  # すでに UTF-8 化されているファイル（二重変換防止）はスキップ
  if grep -qi 'charset=Shift_JIS' "$file"; then
    # CP932(Shift_JIS) -> UTF-8 に変換し、同時に <META ... charset=Shift_JIS> 行を削除
    iconv -f CP932 -t UTF-8 "$file" \
      | sed -E 's/<meta[^>]*charset=["'\'']?Shift_JIS["'\'']?[^>]*>//gi' \
      > "${file}.tmp"
    mv "${file}.tmp" "$file"
  fi
done

echo "Conversion complete."
