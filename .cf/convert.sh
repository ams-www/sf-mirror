#!/bin/bash
set -e

echo "=== 1. 変換ツールの準備 (ffmpeg / cwebp) ==="
BIN_DIR="/tmp/bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

# ffmpeg (静的ビルド) が無ければ取得
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Downloading static ffmpeg..."
  curl -sL https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
    | tar -xJ -C "$BIN_DIR" --strip-components=1 --wildcards '*/ffmpeg'
fi

# cwebp (libwebp) が無ければ取得
if ! command -v cwebp >/dev/null 2>&1; then
  echo "Downloading static cwebp..."
  curl -sL https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0-linux-x86-64.tar.gz \
    | tar -xz -C "$BIN_DIR" --strip-components=2 --wildcards '*/bin/cwebp'
fi

echo "=== 2. HTMLの Shift_JIS -> UTF-8 変換 ==="
find mirror -type f \( -iname "*.htm" -o -iname "*.html" \) | while IFS= read -r file; do
  if grep -qi 'charset=Shift_JIS' "$file"; then
    iconv -f CP932 -t UTF-8 "$file" \
      | sed -E 's/<meta[^>]*charset=["'\'']?Shift_JIS["'\'']?[^>]*>//gi' \
      > "${file}.tmp"
    mv "${file}.tmp" "$file"
  fi
done

echo "=== 3. 画像の WebP 変換 ==="
find mirror -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.gif" \) | while IFS= read -r img; do
  # アニメーションGIFを壊さないよう、GIFは ffmpeg、静止画は cwebp で変換
  if [[ "${img,,}" == *.gif ]]; then
    ffmpeg -nostdin -loglevel error -i "$img" -c:v libwebp -lossless 0 -q:v 80 -loop 0 "${img}.webp"
  else
    cwebp -quiet -q 85 "$img" -o "${img}.webp"
  fi
  rm -f "$img"
done

echo "=== 4. 音声 (WAV / MP3) の WebM (Opus) 変換 ==="
find mirror -type f \( -iname "*.wav" -o -iname "*.mp3" \) | while IFS= read -r audio; do
  ffmpeg -nostdin -loglevel error -i "$audio" -c:a libopus -b:a 96k -vn "${audio}.webm"
  rm -f "$audio"
done

echo "=== 5. HTML / CSS 内の参照パスを .webp / .webm へ一括書き換え ==="
find mirror -type f \( -iname "*.htm" -o -iname "*.html" -o -iname "*.css" \) | while IFS= read -r doc; do
  sed -i -E \
    -e 's/(\.(png|jpg|jpeg|gif))(["'\'' >\)\?])/\1.webp\3/gi' \
    -e 's/(\.(wav|mp3))(["'\'' >\)\?])/\1.webm\3/gi' \
    "$doc"
done

echo "=== 変換完了！ ==="
