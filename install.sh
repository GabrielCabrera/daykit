#!/usr/bin/env bash
set -euo pipefail

# Installer for daykit into a target bin directory (default: ~/.local/bin).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_DIR="${HOME}/.local/bin"
MODE="symlink"
SKIP_BUILD=false

usage() {
  cat <<EOF
Usage: ./install.sh [options]

Options:
  --symlink         Build release binary and create a symlink in --dir (default)
  --copy            Build release binary and copy it into --dir
  --dir <path>      Target bin directory (default: \$HOME/.local/bin)
  --no-build        Skip 'swift build -c release' (uses existing release binary)
  --uninstall       Remove daykit from --dir
  -h, --help        Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --symlink)
      MODE="symlink"
      shift
      ;;
    --copy)
      MODE="copy"
      shift
      ;;
    --dir)
      [[ $# -ge 2 ]] || { echo "error: --dir requires a path" >&2; exit 2; }
      INSTALL_DIR="$2"
      shift 2
      ;;
    --no-build)
      SKIP_BUILD=true
      shift
      ;;
    --uninstall)
      MODE="uninstall"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

TARGET="${INSTALL_DIR}/daykit"

if [[ "${MODE}" == "uninstall" ]]; then
  if [[ -L "${TARGET}" || -e "${TARGET}" ]]; then
    rm -f "${TARGET}"
    echo "Removed ${TARGET}"
  else
    echo "Nothing to remove at ${TARGET}"
  fi
  exit 0
fi

if [[ "${SKIP_BUILD}" == false ]]; then
  swift build --package-path "${SCRIPT_DIR}" -c release
fi

BIN_DIR="$(swift build --package-path "${SCRIPT_DIR}" -c release --show-bin-path)"
SOURCE_BIN="${BIN_DIR}/daykit"

if [[ ! -x "${SOURCE_BIN}" ]]; then
  echo "error: release binary not found at ${SOURCE_BIN}" >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}"

if [[ "${MODE}" == "symlink" ]]; then
  ln -sfn "${SOURCE_BIN}" "${TARGET}"
  echo "Linked ${TARGET} -> ${SOURCE_BIN}"
else
  install -m 0755 "${SOURCE_BIN}" "${TARGET}"
  echo "Installed ${TARGET}"
fi
