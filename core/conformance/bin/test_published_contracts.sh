#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_CONTRACTS_PATH="/home/home/p/g/n/jido_integration/core/contracts"

run_mix() {
  if command -v asdf >/dev/null 2>&1; then
    asdf exec mix "$@"
  else
    mix "$@"
  fi
}

stage_contracts_copy() {
  local stage_dir="$1"
  local artifact_dir="${stage_dir}/jido_integration_v2_contracts"

  mkdir -p "${artifact_dir}"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a \
      --exclude '_build' \
      --exclude 'deps' \
      --exclude '.git' \
      --exclude 'cover' \
      --exclude 'erl_crash.dump' \
      "${DEFAULT_CONTRACTS_PATH}/" "${artifact_dir}/"
  else
    tar -C "${DEFAULT_CONTRACTS_PATH}" -cf - . | tar -C "${artifact_dir}" -xf -
  fi

  printf '%s\n' "${artifact_dir}"
}

cd "${PROJECT_ROOT}"

export JIDO_INTEGRATION_PATH=disabled

if CITADEL_JIDO_INTEGRATION_CONTRACTS_PATH=disabled \
  CITADEL_CONFORMANCE_CONTRACT_MODE=published \
  run_mix deps.get >/tmp/citadel_conformance_published_gate.log 2>&1; then
  export CITADEL_JIDO_INTEGRATION_CONTRACTS_PATH=disabled
  export CITADEL_CONFORMANCE_CONTRACT_MODE=published
  run_mix test "$@"
  exit $?
fi

echo "Published jido_integration_v2_contracts artifact unavailable; falling back to staged artifact copy." >&2

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

export CITADEL_JIDO_INTEGRATION_CONTRACTS_PATH="$(stage_contracts_copy "${STAGE_DIR}")"
export CITADEL_CONFORMANCE_CONTRACT_MODE=staged

run_mix deps.get
run_mix test "$@"
