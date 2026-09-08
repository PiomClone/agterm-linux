#!/usr/bin/env bash
# Personal install of agterm-linux: build Release, then drop the binary, the
# agtermctl CLI, and a desktop entry into ~/.local. Requires the mise toolchain
# (swift 6.3.2) and a vendored libghostty (run scripts/setup-linux.sh once).
#
# Note: the binary finds the vendored libghostty via an absolute rpath into
# agterm-linux/vendor/ghostty/lib, so this is a personal install tied to this
# checkout. A redistributable package must bundle the .so + relocate the rpath
# (and ship a hicolor icon for the .desktop's Icon= key — not included here).
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
# Bridge them (no sudo) for build + install.
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

BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"

echo "Building agterm-linux + agtermctl (Release)…"
( cd agterm-linux && swift build -c release )

install -Dm755 "agterm-linux/.build/release/AgtermLinux" "$BIN_DIR/agterm-linux"
install -Dm755 "agterm-linux/.build/release/agtermctl-linux" "$BIN_DIR/agtermctl"
APP_RESOURCES="agterm-linux/.build/release/agterm-linux_AgtermLinux.resources"
install -d "$BIN_DIR/agterm-linux_AgtermLinux.resources"
cp -R "$APP_RESOURCES/." "$BIN_DIR/agterm-linux_AgtermLinux.resources/"

# Install the vendored ghostty resources (shell-integration + sibling terminfo) so a session resolves
# xterm-ghostty + gets shell-integration without a system ghostty package. The app's resolver checks
# ~/.local/share/agterm/ghostty; libghostty derives TERMINFO from the sibling terminfo dir.
VENDOR_SHARE="agterm-linux/vendor/ghostty/share"
if [ -d "$VENDOR_SHARE/ghostty/shell-integration" ]; then
  RES_DIR="$HOME/.local/share/agterm"
  rm -rf "$RES_DIR/ghostty" "$RES_DIR/terminfo"; mkdir -p "$RES_DIR"
  cp -R "$VENDOR_SHARE/ghostty"  "$RES_DIR/ghostty"
  # terminfo may be absent if the build couldn't stage it (the app then falls back to a system terminfo).
  [ -d "$VENDOR_SHARE/terminfo" ] && cp -R "$VENDOR_SHARE/terminfo" "$RES_DIR/terminfo"
  echo "Installed ghostty resources to $RES_DIR."
else
  echo "Skipped ghostty resources (run scripts/setup-linux.sh to vendor them; the app falls back to /usr/share/ghostty)."
fi

install -Dm644 "packaging/linux/io.github.melonamin.agterm.desktop" \
  "$APP_DIR/io.github.melonamin.agterm.desktop"
# Point every launcher Exec at the installed absolute path while preserving Desktop Action arguments.
sed -i "s|^Exec=agterm-linux\\(.*\\)$|Exec=$BIN_DIR/agterm-linux\\1|" \
  "$APP_DIR/io.github.melonamin.agterm.desktop"
# Remove desktop metadata from pre-migration personal installs so launchers do not show two entries.
rm -f "$APP_DIR/com.umputun.agterm.linux.desktop"

# Generate the hicolor app icon set from the macOS Icon Composer source PNG (no committed binaries),
# so the .desktop's Icon= key + the taskbar/notification icon resolve.
ICON_SRC="$(ls agterm/AppIcon.icon/Assets/*.png 2>/dev/null | head -1)"
ICON_BASE="$HOME/.local/share/icons/hicolor"
if [ -n "$ICON_SRC" ] && command -v magick >/dev/null 2>&1; then
  for sz in 16 32 48 64 128 256 512; do
    install -d "$ICON_BASE/${sz}x${sz}/apps"
    magick "$ICON_SRC" -resize "${sz}x${sz}" "$ICON_BASE/${sz}x${sz}/apps/io.github.melonamin.agterm.png"
    rm -f "$ICON_BASE/${sz}x${sz}/apps/com.umputun.agterm.linux.png"
  done
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -t "$ICON_BASE" 2>/dev/null || true
  echo "Installed hicolor app icons (16-512px)."
else
  echo "Skipped icon install (no source PNG, or 'magick' not on PATH)."
fi

# The custom symbolic toolbar icons (split/scratch/quick/new-workspace/new-session/flag) — copy into
# the hicolor symbolic actions dir so GTK resolves them without the dev search path.
if [ -d "agterm-linux/Resources/icons/hicolor/scalable/actions" ]; then
  install -d "$ICON_BASE/scalable/actions"
  cp agterm-linux/Resources/icons/hicolor/scalable/actions/agterm-*-symbolic.svg "$ICON_BASE/scalable/actions/"
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -t "$ICON_BASE" 2>/dev/null || true
  echo "Installed custom symbolic toolbar icons."
fi

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_DIR" || true

echo "Installed agterm-linux + agtermctl to $BIN_DIR and a desktop entry to $APP_DIR."
echo "Ensure $BIN_DIR is on your PATH."
