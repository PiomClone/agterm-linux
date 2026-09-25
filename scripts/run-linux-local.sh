#!/usr/bin/env bash
# Launch the checkout build from a desktop entry with the same runtime setup as
# run-linux.sh, while keeping its GApplication instance and persisted state
# separate from an installed agterm.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}"

export AGTERM_APP_ID="${AGTERM_APP_ID:-io.github.melonamin.agterm.local}"
export AGTERM_STATE_DIR="${AGTERM_STATE_DIR:-$STATE_BASE/agterm-local}"
# The installed Codex status hook falls back to the package CLI when AGTERMCTL
# is absent. Keep its control protocol in lock-step with this checkout build.
export AGTERMCTL="${AGTERMCTL:-$ROOT/agterm-linux/.build/debug/agtermctl-linux}"

exec "$ROOT/scripts/run-linux.sh" "$@"
