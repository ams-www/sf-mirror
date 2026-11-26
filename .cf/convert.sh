#!/bin/bash
set -e

echo "======変換システムを開始します======"
echo "=== 1. 変換ツールの準備 (ffmpeg / cwebp) ==="
BIN_DIR="/tmp/bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

ARCH=$(uname -m)

# ffmpeg (GitHub BtbN 静的ビルド)
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Downloading static ffmpeg ($ARCH)..."
  if [ "$ARCH" = "aarch64" ]; then
    FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
  else
    FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"
  fi
  curl -fSL "$FFMPEG_URL" | tar -xJ -C "$BIN_DIR" --strip-components=2 --wildcards '*/bin/ffmpeg'
fi

# cwebp (Google公式 libwebp)
if ! command -v cwebp >/dev/null 2>&1; then
  echo "Downloading static cwebp ($ARCH)..."
  if [ "$ARCH" = "aarch64" ]; then
    WEBP_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0-linux-aarch64.tar.gz"
  else
    WEBP_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0-linux-x86-64.tar.gz"
  fi
  curl -fSL "$WEBP_URL" | tar -xz -C "$BIN_DIR" --strip-components=2 --wildcards '*/bin/cwebp'
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
  if [[ "${img,,}" == *.gif ]]; then
    ffmpeg -nostdin -loglevel error -i "$img" \
      -c:v libwebp -lossless 0 -q:v 80 -loop 0 "${img}.webp"

elif [[ "${img,,}" == *.jpg || "${img,,}" == *.jpeg ]]; then
  tmp_png="${img}.tmp.png"

  ffmpeg -nostdin -loglevel error -y -i "$img" \
    -frames:v 1 -pix_fmt rgb24 "$tmp_png"

  cwebp -quiet -q 85 "$tmp_png" -o "${img}.webp"
  rm -f "$tmp_png"

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

echo "======古いアクセス解析・カウンタートラッカーの削除======"
find mirror -type f \( -iname "*.htm" -o -iname "*.html" \) | while IFS= read -r html; do
  perl -0777 -i -pe '
    # 1. 忍者系・NINJA ANALYZE のコメントブロックを削除（■付きや空白ゆれにも対応）
    s/<!--[\s■]*shinobi ct2\s*-->.*?<!--[\s■]*\/shinobi ct2\s*-->//gis;
    s/<!--[\s■]*shinobi1\s*-->.*?<!--[\s■]*shinobi2\s*-->//gis;
    s/<!--[\s■]*NINJA ANALYZE\s*-->.*?<!--[\s■]*\/NINJA ANALYZE\s*-->//gis;
    s/<!--[\s■]*忍び(?:カウンター|アクセス解析)\s*-->\s*(?:<script\b[^>]*>.*?<\/script>\s*(?:<noscript\b[^>]*>.*?<\/noscript>\s*)?)?//gis;

    # 2. Yahoo!アクセス解析ブロックを削除
    s/<!--[\s■]*Yahoo!アクセス解析\s*-->.*?<\/noscript>//gis;

    # 3. 対象ドメインの <script> と、それに続く <noscript> をまとめて削除（改行・空白ゆれ対応）
    s/<script\b[^>]*\bsrc=["\x27][^"\x27]*(?:zouri\.jp|jakou\.com|yu-yake\.com|shinobi\.jp|yimg\.jp\/images\/analytics)[^"\x27]*["\x27][^>]*>.*?<\/script>(?:\s*<noscript\b[^>]*>.*?<\/noscript>)?//gis;
  ' "$html"
done

echo "====== HTTPS混在コンテンツの最小修正 ======"
find mirror -type f | while IFS= read -r doc; do
  case "$doc" in
    *.htm|*.html|*.css)
      perl -0777 -i -pe '
        # ミラー対象ドメインはPages内の同じパスを参照する
        s#https?://(?:www[.])?silver-forest[.]net/#/#gi;

        # ニコニコ動画の旧HTTP埋め込みURLをHTTPS版へ変更
        s#http://ext[.]nicovideo[.]jp/thumb/#https://ext.nicovideo.jp/thumb/#gi;
      ' "$doc"
      ;;
  esac
done
