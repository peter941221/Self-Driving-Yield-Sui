#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
SUI_PROVER_REV="203e7a820fc2816efdeaaf40e79b31667dbea549"
Z3_VERSION="4.15.3"
Z3_ASSET="z3-${Z3_VERSION}-x64-glibc-2.39.zip"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sudo apt-get update
sudo apt-get install -y --no-install-recommends curl unzip ca-certificates build-essential pkg-config libssl-dev

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [ -f "$ROOT_DIR/cache/z3/$Z3_ASSET" ]; then
  cp "$ROOT_DIR/cache/z3/$Z3_ASSET" "$tmp_dir/"
else
  curl -L "https://github.com/Z3Prover/z3/releases/download/z3-${Z3_VERSION}/${Z3_ASSET}" -o "$tmp_dir/$Z3_ASSET"
fi

unzip -q "$tmp_dir/$Z3_ASSET" -d "$tmp_dir"
sudo cp "$tmp_dir/z3-${Z3_VERSION}-x64-glibc-2.39/bin/z3" /usr/local/bin/z3
sudo chmod +x /usr/local/bin/z3

mkdir -p "$HOME/.dotnet" "$HOME/.dotnet/tools"
curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0 --install-dir "$HOME/.dotnet" --version latest
"$HOME/.dotnet/dotnet" tool install --tool-path "$HOME/.dotnet/tools" Boogie || "$HOME/.dotnet/dotnet" tool update --tool-path "$HOME/.dotnet/tools" Boogie

export PATH="$HOME/.cargo/bin:$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"
export DOTNET_ROOT="$HOME/.dotnet"
cargo install --git https://github.com/asymptotic-code/sui-prover.git --rev "$SUI_PROVER_REV" --locked sui-prover

echo "Installed:"
z3 --version | head -n 1
boogie /version || true
"$HOME/.cargo/bin/sui-prover" --version
