#!/usr/bin/env bash
# build-appimage.sh — build the GreenLight AppImage.
# Run from the repo root on Ubuntu (CI uses ubuntu-latest). Run as root in CI.
set -euo pipefail

APP="greenlight"
# Single source of truth: the version in Cargo.toml
VERSION="$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)"
ARCH="x86_64"
BUILD_DIR="build-appimage"
APPDIR="$BUILD_DIR/AppDir"

echo "==> Building $APP $VERSION AppImage"

# ── Build dependencies ────────────────────────────────────────────────
# zsync is installed unconditionally: the guard below evaluates false in CI
# (a prior workflow step already installs cargo), so the guarded block —
# and zsync along with it — was being silently skipped.
apt-get install -y -qq zsync

if ! command -v cargo >/dev/null 2>&1 || ! pkg-config --exists gtk4 2>/dev/null; then
    echo "==> Installing build dependencies"
    apt-get update -qq
    apt-get install -y -qq cargo rustc libgtk-4-dev libadwaita-1-dev \
        pkg-config libssl-dev wget file desktop-file-utils zsync
fi

# ── Release build ─────────────────────────────────────────────────────
echo "==> cargo build --release"
cargo build --release

# ── AppDir layout ─────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
mkdir -p "$APPDIR/usr/bin" \
         "$APPDIR/usr/lib/$APP" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps" \
         "$APPDIR/usr/share/polkit-1/actions" \
         "$APPDIR/usr/share/metainfo"

cp "target/release/$APP"                    "$APPDIR/usr/bin/"
cp scripts/privileged-install.sh            "$APPDIR/usr/lib/$APP/"
chmod 755 "$APPDIR/usr/lib/$APP/privileged-install.sh"
cp data/$APP.desktop                        "$APPDIR/usr/share/applications/"
cp data/$APP-256.png                        "$APPDIR/usr/share/icons/hicolor/256x256/apps/$APP.png"
cp data/io.github.labj1987.GreenLight.policy       "$APPDIR/usr/share/polkit-1/actions/"
cp data/io.github.labj1987.GreenLight.appdata.xml  "$APPDIR/usr/share/metainfo/"

# Top-level AppImage requirements
cp data/$APP.desktop "$APPDIR/"
cp data/$APP-256.png "$APPDIR/$APP.png"

# ── AppRun ────────────────────────────────────────────────────────────
# On first launch the privileged script and polkit policy must exist at
# fixed system paths (polkit refuses relative/user paths), so AppRun
# installs them via pkexec when missing or outdated, then execs the app.
cat > "$APPDIR/AppRun" << 'APPRUN'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "$0")")"
APP="greenlight"

SRC_SCRIPT="$HERE/usr/lib/$APP/privileged-install.sh"
SRC_POLICY="$HERE/usr/share/polkit-1/actions/io.github.labj1987.GreenLight.policy"
DST_SCRIPT="/usr/lib/$APP/privileged-install.sh"
DST_POLICY="/usr/share/polkit-1/actions/io.github.labj1987.GreenLight.policy"

needs_install=0
if [[ ! -f "$DST_SCRIPT" ]] || ! cmp -s "$SRC_SCRIPT" "$DST_SCRIPT"; then
    needs_install=1
fi
if [[ ! -f "$DST_POLICY" ]] || ! cmp -s "$SRC_POLICY" "$DST_POLICY"; then
    needs_install=1
fi

if [[ $needs_install -eq 1 ]]; then
    STAGE="$(mktemp -d)"
    cp "$SRC_SCRIPT" "$STAGE/privileged-install.sh"
    cp "$SRC_POLICY" "$STAGE/policy"
    pkexec bash -c "install -D -m 755 '$STAGE/privileged-install.sh' '$DST_SCRIPT' && install -D -m 644 '$STAGE/policy' '$DST_POLICY'"
    rm -rf "$STAGE"
fi

export PATH="$HERE/usr/bin:$PATH"
exec "$HERE/usr/bin/$APP" "$@"
APPRUN
chmod 755 "$APPDIR/AppRun"

# ── appimagetool ──────────────────────────────────────────────────────
TOOL="$BUILD_DIR/appimagetool"
if [[ ! -f "$TOOL" ]]; then
    echo "==> Downloading appimagetool"
    wget -q -O "$TOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$TOOL"
fi

echo "==> Packing AppImage"
OUT="$APP-$VERSION-$ARCH.AppImage"

UPDATE_INFORMATION="gh-releases-zsync|labj1987|GreenLight|latest|greenlight-*-x86_64.AppImage.zsync"
VERSION="$VERSION" ARCH="$ARCH" "$TOOL" --appimage-extract-and-run \
    -u "$UPDATE_INFORMATION" "$APPDIR" "$OUT"

echo "==> Done: $OUT"
ls -lh "$OUT"

# appimagetool's built-in zsync generation silently no-ops on this runner,
# so build the .zsync sidecar directly. Non-fatal: the AppImage itself is
# already valid without it.
echo "==> Generating .zsync sidecar"
if zsyncmake "$OUT"; then
    echo "==> .zsync generated: $OUT.zsync"
else
    echo "==> WARNING: zsyncmake failed — continuing without .zsync"
fi
