#!/usr/bin/env bash
# ------------------------------------------------------------------
# FNMap Steam Deck bootstrapper
# Installs deps, configures Flutter, builds FNMap, sets capabilities,
# and creates a desktop launcher.
#
# Usage:
#   chmod +x bootstrap_fnmap.sh
#   ./bootstrap_fnmap.sh
#
# Optional env:
#   REENABLE_READONLY=1 ./bootstrap_fnmap.sh   # re-enable SteamOS RO root at end
#   FNMAP_REPO_URL=...                         # override repo (default below)
#   FNMAP_DIR=...                              # override checkout dir (default: ~/fnmap)
# ------------------------------------------------------------------
set -euo pipefail

log() { printf "\033[1;34m[fnmap]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[err]\033[0m  %s\n" "$*"; }

# ---- Settings -----------------------------------------------------
FNMAP_REPO_URL="${FNMAP_REPO_URL:-https://github.com/grmcrkrs/fnmap.git}"
FNMAP_DIR="${FNMAP_DIR:-$HOME/fnmap}"
WRAP_DIR="$HOME/bin"
BUNDLE_DIR="$FNMAP_DIR/build/linux/x64/release/bundle"
DESKTOP_FILE="$HOME/.local/share/applications/fnmap.desktop"
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
ICON_FILE="$ICON_DIR/fnmap.png"

# ---- SteamOS read-only handling ----------------------------------
is_steamos=0
if grep -qi "steamos" /etc/os-release 2>/dev/null; then
  is_steamos=1
fi

if (( is_steamos )); then
  if command -v steamos-readonly >/dev/null 2>&1; then
    ro_state="$(steamos-readonly status 2>/dev/null || true)"
    if echo "$ro_state" | grep -qi "enabled"; then
      log "Disabling SteamOS read-only root..."
      sudo steamos-readonly disable || true
    else
      log "SteamOS root already writable."
    fi
  else
    warn "steamos-readonly tool not found; proceeding."
  fi
fi

# ---- Pacman sync --------------------------------------------------
if command -v pacman >/dev/null 2>&1; then
  log "Syncing pacman databases..."
  sudo pacman -Sy --noconfirm
else
  err "This script expects pacman (Arch/SteamOS). Aborting."
  exit 1
fi

# ---- Base dev toolchain & pkg-config ------------------------------
log "Installing base toolchain and build tools..."
sudo pacman -S --needed --noconfirm \
  base-devel git curl wget unzip zip cmake ninja clang pkgconf which

# ---- GUI & Flutter build deps (GTK, GLib, X11, Wayland, etc.) ----
log "Installing GUI & library dependencies..."
sudo pacman -S --needed --noconfirm \
  gtk3 glib2 pango cairo at-spi2-core gdk-pixbuf2 \
  harfbuzz freetype2 fontconfig graphite libpng libjpeg-turbo libtiff \
  zlib libx11 libxext libxrender libxcb libxau libxdmcp xorgproto \
  wayland wayland-protocols libxkbcommon libepoxy dbus polkit \
  json-glib libffi fribidi libthai libdatrie libxft libxtst \
  systemd sysprof

# headers (kernel + glibc headers)
log "Ensuring kernel headers and glibc headers are present..."
if ! pacman -Qs linux-headers >/dev/null 2>&1; then
  # Try common names used on Steam Deck kernels
  sudo pacman -S --needed --noconfirm linux-headers || true
  sudo pacman -S --needed --noconfirm linux-neptune-headers || true
  sudo pacman -S --needed --noconfirm linux-neptune-611-headers || true
fi
sudo pacman -S --needed --noconfirm glibc

# ---- Flutter install (via pacman preferred) -----------------------
if ! command -v flutter >/dev/null 2>&1; then
  log "Installing Flutter (pacman)..."
  sudo pacman -S --needed --noconfirm flutter dart || true
fi

if ! command -v flutter >/dev/null 2>&1; then
  log "Flutter not available via pacman; installing from tarball..."
  FLUTTER_DIR="$HOME/flutter"
  mkdir -p "$FLUTTER_DIR"
  cd "$FLUTTER_DIR"
  # Grab latest stable SDK tarball
  # Note: URL pattern from Flutter docs
  curl -LO https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.3-stable.tar.xz
  tar xf flutter_linux_3.24.3-stable.tar.xz
  export PATH="$FLUTTER_DIR/flutter/bin:$PATH"
else
  # Ensure PATH has flutter when installed by pacman (usually /usr/bin already in PATH)
  :;
fi

log "Flutter version:"
flutter --version || { err "Flutter failed to run."; exit 1; }

log "Enabling Linux desktop support..."
flutter config --enable-linux-desktop || true

# ---- Checkout or update FNMap source ------------------------------
if [[ -d "$FNMAP_DIR/.git" ]]; then
  log "Updating existing FNMap repo at $FNMAP_DIR ..."
  git -C "$FNMAP_DIR" fetch --all --tags
  git -C "$FNMAP_DIR" pull --rebase --autostash
else
  log "Cloning FNMap repo to $FNMAP_DIR ..."
  git clone "$FNMAP_REPO_URL" "$FNMAP_DIR"
fi

# ---- Pin known-good dependency to avoid build break ----------------
# Font Awesome Flutter 10.9.0+ hits a Color.withValues issue on some SDK mixes.
# We'll pin to 10.7.0 unless the pubspec already declares an exact version line.
if grep -qE 'font_awesome_flutter:\s*\^' "$FNMAP_DIR/pubspec.yaml"; then
  log "Patching pubspec to pin font_awesome_flutter to 10.7.0..."
  sed -i 's/font_awesome_flutter:\s*\^.*$/font_awesome_flutter: 10.7.0/' "$FNMAP_DIR/pubspec.yaml"
fi

# ---- Ensure a Linux desktop project exists ------------------------
cd "$FNMAP_DIR"
if [[ ! -d linux ]]; then
  log "Adding Linux platform files to the Flutter project..."
  flutter create . --platforms=linux
fi

# ---- Fetch deps & build -------------------------------------------
log "Fetching Flutter dependencies..."
flutter pub get

log "Building release bundle for Linux..."
flutter build linux --release

if [[ ! -f "$BUNDLE_DIR/fnmap" ]]; then
  err "Build finished but fnmap binary not found at $BUNDLE_DIR."
  exit 1
fi

# ---- Grant raw socket caps (no sudo needed to run) -----------------
log "Granting network capabilities to fnmap binary (no sudo required to run)..."
sudo setcap 'cap_net_raw,cap_net_admin+ep' "$BUNDLE_DIR/fnmap" || warn "setcap failed; you may be prompted for sudo when running."

# ---- Wrapper script to export LD_LIBRARY_PATH ----------------------
mkdir -p "$WRAP_DIR"
RUN_WRAP="$WRAP_DIR/fnmap-run.sh"
cat > "$RUN_WRAP" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BUNDLE_DIR="$HOME/fnmap/build/linux/x64/release/bundle"
if [[ ! -x "$BUNDLE_DIR/fnmap" ]]; then
  echo "FNMap binary not found at $BUNDLE_DIR. Did the build succeed?" >&2
  exit 1
fi
export LD_LIBRARY_PATH="$BUNDLE_DIR/lib:${LD_LIBRARY_PATH:-}"
exec "$BUNDLE_DIR/fnmap" "$@"
EOF
chmod +x "$RUN_WRAP"

# ---- Desktop file & icon ------------------------------------------
mkdir -p "$(dirname "$DESKTOP_FILE")" "$ICON_DIR"

# Try to copy an icon from repo if present
if [[ -f "$FNMAP_DIR/assets/icon.png" ]]; then
  cp -f "$FNMAP_DIR/assets/icon.png" "$ICON_FILE"
elif [[ -f "$FNMAP_DIR/linux/icon.png" ]]; then
  cp -f "$FNMAP_DIR/linux/icon.png" "$ICON_FILE"
fi

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=FNMap
Comment=Flutter Network Mapper
Exec=$RUN_WRAP
Icon=${ICON_FILE%.*}
Terminal=false
Categories=Network;Utility;
EOF

# Rebuild desktop DB and KDE cache if available
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
if command -v kbuildsycoca6 >/dev/null 2>&1; then
  kbuildsycoca6 >/dev/null 2>&1 || true
elif command -v kbuildsycoca5 >/dev/null 2>&1; then
  kbuildsycoca5 >/dev/null 2>&1 || true
fi

log "FNMap installed. You can launch it from the app menu or run: $RUN_WRAP"

# ---- Optionally re-enable read-only root ---------------------------
if (( is_steamos )) && [[ "${REENABLE_READONLY:-0}" == "1" ]]; then
  log "Re-enabling SteamOS read-only root..."
  sudo steamos-readonly enable || warn "Failed to re-enable read-only root."
fi

log "Done."
