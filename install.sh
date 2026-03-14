#!/bin/sh
set -eu

REPO="${SYMPHONY_PI_GITHUB_REPO:-dzmbs/symphony-pi}"
VERSION="${SYMPHONY_PI_VERSION:-latest}"
INSTALL_DIR="${SYMPHONY_PI_INSTALL_DIR:-$HOME/.local/share/symphony-pi}"
BIN_DIR="${SYMPHONY_PI_BIN_DIR:-$HOME/.local/bin}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux) echo "linux" ;;
    *)
      echo "Unsupported operating system: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    arm64|aarch64) echo "arm64" ;;
    *)
      echo "Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

checksum_cmd() {
  if command -v shasum >/dev/null 2>&1; then
    echo "shasum -a 256"
  elif command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum"
  else
    echo "" >&2
    return 1
  fi
}

verify_checksum() {
  asset="$1"
  checksums_file="$2"
  checksum_tool="$3"

  expected="$(grep "  $asset\$" "$checksums_file" | awk '{print $1}')"

  if [ -z "$expected" ]; then
    echo "Could not find checksum for $asset" >&2
    exit 1
  fi

  actual="$(cd "$(dirname "$checksums_file")" && $checksum_tool "$asset" | awk '{print $1}')"

  if [ "$expected" != "$actual" ]; then
    echo "Checksum verification failed for $asset" >&2
    exit 1
  fi
}

download_base() {
  if [ "$VERSION" = "latest" ]; then
    echo "https://github.com/$REPO/releases/latest/download"
  else
    echo "https://github.com/$REPO/releases/download/$VERSION"
  fi
}

main() {
  need_cmd curl
  need_cmd tar
  need_cmd mktemp

  os="$(detect_os)"
  arch="$(detect_arch)"
  asset="symphony-pi-${os}-${arch}.tar.gz"
  base="$(download_base)"
  checksum_tool="$(checksum_cmd)"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT INT TERM

  echo "Downloading Symphony Pi release asset: $asset"
  curl -fsSL "$base/$asset" -o "$tmpdir/$asset"
  curl -fsSL "$base/SHA256SUMS" -o "$tmpdir/SHA256SUMS"

  verify_checksum "$asset" "$tmpdir/SHA256SUMS" "$checksum_tool"

  mkdir -p "$BIN_DIR"
  rm -rf "$INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  mkdir -p "$tmpdir/extract"
  tar -xzf "$tmpdir/$asset" -C "$tmpdir/extract"
  mv "$tmpdir/extract/symphony-pi" "$INSTALL_DIR"

  ln -sf "$INSTALL_DIR/bin/symphony-pi" "$BIN_DIR/symphony-pi"

  echo
  echo "Installed Symphony Pi to $INSTALL_DIR"
  echo "Linked CLI at $BIN_DIR/symphony-pi"

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      echo
      echo "Add $BIN_DIR to your PATH to run \`symphony-pi\` directly."
      ;;
  esac

  echo
  echo "Next steps:"
  echo "  1. Make sure \`pi\` is installed and authenticated."
  echo "  2. Run: symphony-pi setup /path/to/your-repo"
  echo "  3. Run: symphony-pi /path/to/your-repo --i-understand-that-this-will-be-running-without-the-usual-guardrails"
}

main "$@"
