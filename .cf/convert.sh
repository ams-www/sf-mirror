#!/bin/bash
set -e

echo "======変換システムを開始します======"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
echo "並列数: $JOBS"

# ---------- 1. ツール準備（並列DL） ----------
echo "=== 1. 変換ツールの準備 (ffmpeg / cwebp) ==="
BIN_DIR="/tmp/bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"
ARCH=$(uname -m)

fetch_ffmpeg() {
  command -v ffmpeg >/dev/null 2>&1 && return 0
  echo "[ffmpeg] downloading ($ARCH)..."
  local url
  if [ "$ARCH" = "aarch64" ]; then
    url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
  else
    url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"
  fi
  curl -fSL "$url" | tar -xJ -C "$BIN_DIR" --strip-components=2 --wildcards '*/bin/ffmpeg'
}

fetch_webp() {
  command -v cwebp >/dev/null 2>&1 && return 0
  echo "[webp] downloading ($ARCH)..."
  local url
  if [ "$ARCH" = "aarch64" ]; then
    url="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0-linux-aarch64.tar.gz"
  else
    url="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0-linux-x86-64.tar.gz"
  fi
  # gif2webp 同梱版を試す
  curl -fSL "$url" | tar -xz -C "$BIN_DIR" --strip-components=2 \
    --wildcards '*/bin/cwebp' '*/bin/gif2webp' 2>/dev/null \
  || curl -fSL "$url" | tar -xz -C "$BIN_DIR" --strip-components=2 --wildcards '*/bin/cwebp'
}

fetch_ffmpeg & P1=$!
fetch_webp   & P2=$!
wait $P1; wait $P2

HAS_GIF2WEBP=0
command -v gif2webp >/dev/null 2>&1 && HAS_GIF2WEBP=1
export HAS_GIF2WEBP
echo "gif2webp: $([ "$HAS_GIF2WEBP" = 1 ] && echo 'あり(高速)' || echo 'なし→ffmpegフォールバック')"

# ---------- 2. Shift_JIS → UTF-8 ----------
echo "=== 2. HTMLの Shift_JIS -> UTF-8 変換 ==="
do_sjis() {
  local file="$1"
  if grep -qi "charset=Shift_JIS" "$file"; then
    iconv -f CP932 -t UTF-8 "$file" \
      | sed -E 's/<meta[^>]*charset=["'\'']?Shift_JIS["'\'']?[^>]*>//gi' \
      > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi
}
export -f do_sjis
find mirror -type f \( -iname "*.htm" -o -iname "*.html" \) -print0 \
  | xargs -0 -r -P "$JOBS" -n 1 bash -c 'do_sjis "$1"' _

# ---------- 3. 画像 → WebP ----------
echo "=== 3. 画像の WebP 変換 ==="
do_img() {
  local img="$1"
  local lower="${img,,}"
  local ok=0

  case "$lower" in
    *.gif)
      if [ "${HAS_GIF2WEBP:-0}" = "1" ]; then
        gif2webp -quiet -q 80 "$img" -o "${img}.webp" 2>/dev/null && ok=1
      fi
      if [ "$ok" = 0 ]; then
        ffmpeg -nostdin -loglevel error -i "$img" \
          -c:v libwebp -lossless 0 -q:v 80 -loop 0 "${img}.webp" 2>/dev/null && ok=1
      fi
      ;;

    *.jpg|*.jpeg)
      # 1st try: cwebp 直接（RGB JPEG はこれで最速）
      if cwebp -quiet -q 85 "$img" -o "${img}.webp" 2>/dev/null; then
        ok=1
      else
        # CMYK / YCCK / 特殊色空間の JPEG は ffmpeg で RGB 化してから cwebp
        echo "[fallback:ffmpeg] $img"
        local tmp_png="${img}.tmp.png"
        if ffmpeg -nostdin -loglevel error -y -i "$img" \
             -frames:v 1 -pix_fmt rgb24 "$tmp_png" 2>/dev/null \
           && cwebp -quiet -q 85 "$tmp_png" -o "${img}.webp" 2>/dev/null; then
          ok=1
        fi
        rm -f "$tmp_png"
      fi
      ;;

    *)
      # PNG はそのまま cwebp（iCCP 警告は 2>/dev/null で抑制）
      cwebp -quiet -q 85 "$img" -o "${img}.webp" 2>/dev/null && ok=1
      ;;
  esac

  if [ "$ok" = 1 ]; then
    rm -f "$img"
  else
    echo "[WARN] 変換失敗、元ファイル保持: $img" >&2
    # ★重要★ exit 255 で xargs 全体が abort するのを防ぐため必ず 0 を返す
  fi
  return 0
}
export -f do_img
find mirror -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.gif" \) -print0 \
  | xargs -0 -r -P "$JOBS" -n 1 bash -c 'do_img "$1"' _

  
# ---------- 4. 音声 → WebM ----------
echo "=== 4. 音声 (WAV / MP3) の WebM (Opus) 変換 ==="
do_audio() {
  local audio="$1"
  ffmpeg -nostdin -loglevel error -i "$audio" \
    -c:a libopus -b:a 96k -vn "${audio}.webm" && rm -f "$audio"
}
export -f do_audio
find mirror -type f \( -iname "*.wav" -o -iname "*.mp3" \) -print0 \
  | xargs -0 -r -P "$JOBS" -n 1 bash -c 'do_audio "$1"' _

# ---------- 5. 参照パス書き換え ----------
echo "=== 5. HTML / CSS 内の参照パスを .webp / .webm へ一括書き換え ==="
do_rewrite() {
  local doc="$1"
  sed -i -E \
    -e 's/(\.(png|jpg|jpeg|gif))(["'\'' >\)\?])/\1.webp\3/gi' \
    -e 's/(\.(wav|mp3))(["'\'' >\)\?])/\1.webm\3/gi' \
    "$doc"
}
export -f do_rewrite
find mirror -type f \( -iname "*.htm" -o -iname "*.html" -o -iname "*.css" \) -print0 \
  | xargs -0 -r -P "$JOBS" -n 1 bash -c 'do_rewrite "$1"' _

echo "=== 変換完了！ ==="

# ---------- 6. 解析タグ削除 ----------
echo "======古いアクセス解析・カウンタートラッカーの削除======"
do_strip() {
  local html="$1"
  perl -0777 -i -pe '
    s/<!--[\s■]*shinobi ct2\s*-->.*?<!--[\s■]*\/shinobi ct2\s*-->//gis;
    s/<!--[\s■]*shinobi1\s*-->.*?<!--[\s■]*shinobi2\s*-->//gis;
    s/<!--[\s■]*NINJA ANALYZE\s*-->.*?<!--[\s■]*\/NINJA ANALYZE\s*-->//gis;
    s/<!--[\s■]*忍び(?:カウンター|アクセス解析)\s*-->\s*(?:<script\b[^>]*>.*?<\/script>\s*(?:<noscript\b[^>]*>.*?<\/noscript>\s*)?)?//gis;
    s/<!--[\s■]*Yahoo!アクセス解析\s*-->.*?<\/noscript>//gis;
    s/<script\b[^>]*\bsrc=["\x27][^"\x27]*(?:zouri\.jp|jakou\.com|yu-yake\.com|shinobi\.jp|yimg\.jp\/images\/analytics)[^"\x27]*["\x27][^>]*>.*?<\/script>(?:\s*<noscript\b[^>]*>.*?<\/noscript>)?//gis;
  ' "$html"
}
export -f do_strip
find mirror -type f \( -iname "*.htm" -o -iname "*.html" \) -print0 \
  | xargs -0 -r -P "$JOBS" -n 1 bash -c 'do_strip "$1"' _

# ---------- 7. HTTPS 混在修正 ----------
echo "====== HTTPS混在コンテンツの最小修正 ======"
do_https() {
  local doc="$1"
  perl -0777 -i -pe '
    s#https?://(?:www[.])?silver-forest[.]net/#/#gi;
    s#http://ext[.]nicovideo[.]jp/thumb/#https://ext.nicovideo.jp/thumb/#gi;
  ' "$doc"
}
export -f do_https
find mirror -type f \( -iname "*.htm" -o -iname "*.html" -o -iname "*.css" \) -print0 \
  | xargs -0 -r -P "$JOBS" -n 1 bash -c 'do_https "$1"' _

echo "======すべての変換が完了しました======"
