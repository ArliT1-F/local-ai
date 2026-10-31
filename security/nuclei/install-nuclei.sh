#!/usr/bin/env bash
# Install the official nuclei binary from projectdiscovery/nuclei GitHub releases
# into ./bin, verifying the published SHA-256 checksum.
#
#   bash security/nuclei/install-nuclei.sh            # latest release
#   NUCLEI_VERSION=3.3.7 bash security/nuclei/install-nuclei.sh
#
# Docs: https://github.com/projectdiscovery/nuclei
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_DIR="$ROOT/bin"
API="${NUCLEI_API:-https://api.github.com/repos/projectdiscovery/nuclei/releases}"
DL="${NUCLEI_DOWNLOAD:-https://github.com/projectdiscovery/nuclei/releases/download}"

command -v curl >/dev/null || { echo "error: curl is required" >&2; exit 1; }

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64 | amd64) arch="amd64" ;;
  aarch64 | arm64) arch="arm64" ;;
  *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
case "$os" in
  linux | darwin) ;;
  *) echo "error: unsupported OS $os (see https://github.com/projectdiscovery/nuclei)" >&2; exit 1 ;;
esac

version="${NUCLEI_VERSION:-}"
if [[ -z "$version" ]]; then
  version="$(curl -fsSL "$API/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$version" ]] || { echo "error: could not resolve the latest nuclei release" >&2; exit 1; }
fi
ver="${version#v}"
asset="nuclei_${ver}_${os}_${arch}.zip"
url="${DL}/${version}/${asset}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading nuclei ${version} (${os}/${arch})"
curl -fSL --retry 3 -o "$tmp/$asset" "$url"
curl -fSL --retry 3 -o "$tmp/checksums.txt" "${DL}/${version}/nuclei_${ver}_checksums.txt"

echo "Verifying checksum"
expected="$(grep -E "[[:space:]]\*?${asset}\$" "$tmp/checksums.txt" | awk '{print $1}' | head -1)"
[[ -n "$expected" ]] || { echo "error: no checksum entry for ${asset}" >&2; exit 1; }
if command -v sha256sum >/dev/null; then
  actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
fi
if [[ "$expected" != "$actual" ]]; then
  echo "error: checksum mismatch for ${asset}" >&2
  echo "  expected $expected" >&2
  echo "  actual   $actual" >&2
  exit 1
fi

echo "Extracting"
mkdir -p "$BIN_DIR"
if command -v unzip >/dev/null; then
  unzip -o -q "$tmp/$asset" -d "$tmp/extracted"
else
  python3 - "$tmp/$asset" "$tmp/extracted" <<'PY'
import sys, zipfile, os
os.makedirs(sys.argv[2], exist_ok=True)
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
fi
install -m 0755 "$tmp/extracted/nuclei" "$BIN_DIR/nuclei"

echo "Installed: $("$BIN_DIR/nuclei" -version 2>&1 | head -3 | tr '\n' ' ')"
echo
echo "Templates are NOT bundled. The first scan downloads nuclei-templates into"
echo "~/.local/nuclei-templates (see security/nuclei/scan.sh)."
echo "Alternative install, if you prefer Go: go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
