#!/usr/bin/env bash
# Downloads a pinned version of the Zig compiler for Linux x86_64 and
# extracts it into ./zig/cache/, then exposes ./zig/zig as the binary.
#
# Usage:
#   ./zig/download.sh
#
# Re-running this script is cheap: if the requested version is already
# extracted in the cache, it skips the download entirely.

set -euo pipefail

# --- Configuration ----------------------------------------------------------
# Values below are taken from https://ziglang.org/download/index.json.
# Bump ZIG_VERSION, ZIG_URL and ZIG_SHA256 together when upgrading.

ZIG_VERSION="0.16.0"
ZIG_TARBALL="zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"
ZIG_SHA256="43186959edc87d5c7a1be7b7d2a25efffd22ce5807c7af99067f86f99641bfdf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/cache"
INSTALL_DIR="${CACHE_DIR}/zig-x86_64-linux-${ZIG_VERSION}"
BIN_LINK="${SCRIPT_DIR}/zig"

# --- Skip if already installed ----------------------------------------------

if [ -x "${INSTALL_DIR}/zig" ]; then
  echo "zig ${ZIG_VERSION} already downloaded, skipping."
else
  echo "Downloading zig ${ZIG_VERSION}..."
  mkdir -p "${CACHE_DIR}"

  TMP_TARBALL="$(mktemp)"
  trap 'rm -f "${TMP_TARBALL}"' EXIT

  curl -fL --retry 3 --retry-delay 2 -o "${TMP_TARBALL}" "${ZIG_URL}"

  echo "${ZIG_SHA256}  ${TMP_TARBALL}" | sha256sum -c -

  tar -xJf "${TMP_TARBALL}" -C "${CACHE_DIR}"
fi

# --- Expose ./zig/zig as the binary -----------------------------------------

ln -sf "${INSTALL_DIR}/zig" "${BIN_LINK}"

"${BIN_LINK}" version

# Make `zig` available to subsequent steps in GitHub Actions.
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "${SCRIPT_DIR}" >> "${GITHUB_PATH}"
fi