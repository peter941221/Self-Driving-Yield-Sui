#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PATH="$HOME/.cargo/bin:$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"
export DOTNET_ROOT="$HOME/.dotnet"
export BOOGIE_EXE="$HOME/.dotnet/tools/boogie"
export Z3_EXE="$(command -v z3 || true)"

if ! command -v sui-prover >/dev/null 2>&1; then
  echo "sui-prover not found in PATH. Run scripts/install_sui_prover_wsl.sh first." >&2
  exit 1
fi

if ! command -v boogie >/dev/null 2>&1; then
  echo "boogie not found in PATH. Run scripts/install_sui_prover_wsl.sh first." >&2
  exit 1
fi

if ! command -v z3 >/dev/null 2>&1; then
  echo "z3 not found in PATH. Run scripts/install_sui_prover_wsl.sh first." >&2
  exit 1
fi

if [ -z "$Z3_EXE" ]; then
  echo "Z3_EXE could not be resolved." >&2
  exit 1
fi

cd "$ROOT_DIR"
exec sui-prover --path formal "$@"
