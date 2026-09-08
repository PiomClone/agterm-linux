#!/usr/bin/env bash
# Build and launch agterm-linux (the GTK4/libadwaita port).
# Requires the mise toolchain (zig 0.16.0 + swift 6.3.2) and a built libghostty
# in agterm-linux/vendor/ (run scripts/setup-linux.sh once).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -d "$HOME/.local/share/mise/installs/swift/6.3.2/usr" ]; then
  SWIFT_HOME="$HOME/.local/share/mise/installs/swift/6.3.2"
elif [ -d "$HOME/prj/.tools/mise/data/installs/swift/6.3.2/usr" ]; then
  SWIFT_HOME="$HOME/prj/.tools/mise/data/installs/swift/6.3.2"
else
  SWIFT_HOME="$HOME/.local/share/mise/installs/swift/6.3.2"
fi
COMPAT="$HOME/.local/share/swift-linux-compat"
export PATH="$SWIFT_HOME/usr/bin:$PATH"

# Arch and Debian/Ubuntu place ncurses/libxml2 in different lib paths.
# Bridge them (no sudo) for build + run.
LIBNCURSES_SRC="$(ls /usr/lib*/libncursesw.so.6 /usr/lib/*/libncursesw.so.6 /usr/lib*/libncurses.so.6 /usr/lib/*/libncurses.so.6 2>/dev/null | head -n 1 || true)"
LIBXML2_SRC="$(ls /usr/lib*/libxml2.so.* /usr/lib/*/libxml2.so.* 2>/dev/null | sort -V | tail -n 1 || true)"

mkdir -p "$COMPAT"
if [ ! -e "$COMPAT/libncurses.so.6" ] && [ -n "$LIBNCURSES_SRC" ]; then
  ln -sf "$LIBNCURSES_SRC" "$COMPAT/libncurses.so.6"
fi
if [ ! -e "$COMPAT/libxml2.so.2" ] && [ -n "$LIBXML2_SRC" ]; then
  ln -sf "$LIBXML2_SRC" "$COMPAT/libxml2.so.2"
fi
export LD_LIBRARY_PATH="$COMPAT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Point the dev build at the vendored ghostty resources (shell-integration + sibling terminfo) so
# GHOSTTY_RESOURCES_DIR resolves to them (else the resolver falls back to a system/installed dir).
export AGTERM_GHOSTTY_RESOURCES="$(pwd)/agterm-linux/vendor/ghostty/share/ghostty"

cd agterm-linux
swift build "$@"
exec ./.build/debug/AgtermLinux
