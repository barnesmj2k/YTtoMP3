#!/bin/bash
# Installs "YouTube to MP3" into DaVinci Resolve's Workspace > Scripts menu,
# plus the standalone tools it runs (yt-dlp, ffmpeg/ffprobe, Deno).
#
#   ./install.sh            install the script; download any tools that are missing
#   ./install.sh --update   also re-download every tool at its latest version
set -euo pipefail

APP_DIR="$HOME/Library/Application Support/YTtoMP3"
BIN="$APP_DIR/bin"
SCRIPTS_DIR="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility"
HERE="$(cd "$(dirname "$0")" && pwd)"
UPDATE=0
[[ "${1:-}" == "--update" ]] && UPDATE=1

case "$(uname -m)" in
  arm64)  DENO_ASSET="deno-aarch64-apple-darwin.zip"; FF_ARCH="arm64" ;;
  x86_64) DENO_ASSET="deno-x86_64-apple-darwin.zip";  FF_ARCH="amd64" ;;
  *) echo "Unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$BIN" "$SCRIPTS_DIR"

fetch() { curl -fL --retry 3 --progress-bar -o "$2" "$1"; }

# verify <file> <expected sha256>
verify() {
  local actual
  actual="$(shasum -a 256 "$1" | awk '{print $1}')"
  if [[ "$actual" != "$2" ]]; then
    echo "Checksum mismatch for $(basename "$1") (expected $2, got $actual)" >&2
    exit 1
  fi
}

need() { [[ $UPDATE == 1 || ! -x "$BIN/$1" ]]; }

if need yt-dlp; then
  echo "==> yt-dlp (github.com/yt-dlp/yt-dlp)"
  if ! curl -fsS --max-time 15 -o /dev/null https://github.com 2>/dev/null; then
    echo "Can't reach github.com." >&2
    echo "GitHub only works over IPv4. If your Mac's IP address starts with 169.254 it has no IPv4 connection:" >&2
    echo "System Settings > Wi-Fi > Details > TCP/IP > Renew DHCP Lease (or restart your router), then try again." >&2
    exit 1
  fi
  base="https://github.com/yt-dlp/yt-dlp/releases/latest/download"
  fetch "$base/yt-dlp_macos" "$TMP/yt-dlp_macos"
  fetch "$base/SHA2-256SUMS" "$TMP/yt-dlp.sums"
  verify "$TMP/yt-dlp_macos" "$(awk '$2=="yt-dlp_macos"{print $1}' "$TMP/yt-dlp.sums")"
  install -m 755 "$TMP/yt-dlp_macos" "$BIN/yt-dlp"
fi

if need deno; then
  echo "==> Deno (dl.deno.land)"
  base="https://dl.deno.land/release/$(curl -fsSL https://dl.deno.land/release-latest.txt)"
  fetch "$base/$DENO_ASSET" "$TMP/deno.zip"
  fetch "$base/$DENO_ASSET.sha256sum" "$TMP/deno.sum"
  verify "$TMP/deno.zip" "$(awk '{print $1}' "$TMP/deno.sum")"
  unzip -oq "$TMP/deno.zip" -d "$TMP/deno"
  install -m 755 "$TMP/deno/deno" "$BIN/deno"
fi

if need ffmpeg || need ffprobe; then
  echo "==> ffmpeg + ffprobe (ffmpeg.martin-riedl.de, release build)"
  site="https://ffmpeg.martin-riedl.de"
  dir="$(curl -fsL "$site/" | grep -oE "/download/macos/$FF_ARCH/[0-9]+_[0-9][0-9.]*/ffmpeg\.zip\"" | head -1 | sed 's#/ffmpeg\.zip"$##')"
  if [[ -z "$dir" ]]; then
    echo "Couldn't find the ffmpeg release build on $site" >&2
    exit 1
  fi
  for tool in ffmpeg ffprobe; do
    fetch "$site$dir/$tool.zip" "$TMP/$tool.zip"
    verify "$TMP/$tool.zip" "$(curl -fsL "$site$dir/$tool.zip.sha256" | awk '{print $1}')"
    unzip -oq "$TMP/$tool.zip" -d "$TMP/$tool"
    install -m 755 "$TMP/$tool/$tool" "$BIN/$tool"
  done
fi

# Files fetched with curl aren't quarantined, but clear the flag in case they were copied in by hand.
xattr -dr com.apple.quarantine "$BIN" 2>/dev/null || true

echo "==> Checking tools"
"$BIN/yt-dlp" --version | sed 's/^/    yt-dlp  /'
"$BIN/deno" --version | head -1 | sed 's/^/    /'
"$BIN/ffmpeg" -hide_banner -version | head -1 | sed 's/^/    /'

echo "==> Installing script into Resolve"
install -m 644 "$HERE/YouTube to MP3.lua" "$SCRIPTS_DIR/YouTube to MP3.lua"

echo
echo "Done. In DaVinci Resolve choose Workspace > Scripts > YouTube to MP3."
echo "(If it isn't listed yet, restart Resolve once.)"
