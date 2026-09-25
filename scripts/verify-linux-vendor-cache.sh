#!/usr/bin/env bash
# Verify that a vendored libghostty cache is complete and belongs to the current Linux host.
set -euo pipefail

if (( $# != 1 )); then
  echo "usage: scripts/verify-linux-vendor-cache.sh VENDOR_DIRECTORY" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$1"
[[ "$VENDOR" = /* ]] || VENDOR="$ROOT/$VENDOR"
PATCH_DIGEST="$(sha256sum \
  "$ROOT/linux/patches/ghostty-embedded-opengl.patch" \
  "$ROOT/linux/patches/ghostty-embedded-input-handoff.patch" \
  "$ROOT/linux/patches/ghostty-embedded-conditional-env.patch" \
  "$ROOT/linux/patches/ghostty-lib-resources.patch" \
  | sha256sum | awk '{print $1}')"

for required in lib/libghostty.so include/ghostty.h include/ghostty/vt.h; do
  [[ -s "$VENDOR/$required" ]] || {
    echo "missing or empty vendored libghostty file: $VENDOR/$required" >&2
    exit 1
  }
done

[[ "$(<"$VENDOR/.agterm-ghostty-patches.sha256")" == "$PATCH_DIGEST" ]] || {
  echo "vendored libghostty was built with different Linux patches" >&2
  exit 1
}

"$ROOT/scripts/verify-linux-architecture.sh" "$VENDOR/lib/libghostty.so"
"$ROOT/scripts/verify-linux-resources.sh" "$VENDOR/share"
echo "→ verified current-architecture libghostty cache at $VENDOR"
