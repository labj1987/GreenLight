#!/usr/bin/env bash
# build-appimage.sh — Build nvidia-driver-installer as an AppImage
set -euo pipefail

APP="nvidia-driver-installer"
# Single source of truth: the version in Cargo.toml
VERSION="$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)"
APPDIR="$(pwd)/AppDir"

echo "==> Checking build dependencies…"
apt-get install -y \
    cargo \
    rustc \
    libgtk-4-dev \
    libadwaita-1-dev \
    pkg-config \
    libssl-dev \
    wget \
    zsync

apt-get install -y libfuse2 2>/dev/null \
    || apt-get install -y libfuse2t64 2>/dev/null \
    || echo "NOTE: libfuse2 not available — run the AppImage with --appimage-extract-and-run"

echo "==> Building release binary…"
cargo build --release

echo "==> Setting up AppDir…"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib/${APP}"
mkdir -p "$APPDIR/usr/share/applications"
mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$APPDIR/usr/share/polkit-1/actions"
mkdir -p "$APPDIR/usr/share/metainfo"

install -Dm755 "target/release/${APP}" "$APPDIR/usr/bin/${APP}"

install -Dm755 "scripts/privileged-install.sh" \
    "$APPDIR/usr/lib/${APP}/privileged-install.sh"

install -Dm644 "data/io.github.labj1987.NVI.policy" \
    "$APPDIR/usr/share/polkit-1/actions/io.github.labj1987.NVI.policy"

install -Dm644 "data/io.github.labj1987.NVI.appdata.xml" \
    "$APPDIR/usr/share/metainfo/io.github.labj1987.NVI.appdata.xml"

install -Dm644 "data/nvidia-driver-installer.desktop" \
    "$APPDIR/usr/share/applications/nvidia-driver-installer.desktop"
cp "data/nvidia-driver-installer.desktop" "$APPDIR/nvidia-driver-installer.desktop"

install -Dm644 "data/nvidia-driver-installer-256.png" \
    "$APPDIR/usr/share/icons/hicolor/256x256/apps/nvidia-driver-installer.png"
cp "data/nvidia-driver-installer-256.png" "$APPDIR/nvidia-driver-installer.png"

cat > "$APPDIR/AppRun" << 'APPRUN'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "$0")")"

PRIV_SRC="${HERE}/usr/lib/nvidia-driver-installer/privileged-install.sh"
PRIV_DST="/usr/lib/nvidia-driver-installer/privileged-install.sh"
POLICY_SRC="${HERE}/usr/share/polkit-1/actions/io.github.labj1987.NVI.policy"
POLICY_DST="/usr/share/polkit-1/actions/io.github.labj1987.NVI.policy"

need_install=0
[[ -f "$PRIV_DST" ]]   || need_install=1
[[ -f "$POLICY_DST" ]] || need_install=1
if [[ $need_install -eq 0 ]]; then
    cmp -s "$PRIV_SRC" "$PRIV_DST"     || need_install=1
    cmp -s "$POLICY_SRC" "$POLICY_DST" || need_install=1
fi

if [[ $need_install -eq 1 ]]; then
    echo "Installing/updating privileged components (password required)…"

    STAGE="$(mktemp -d /tmp/nvidia-driver-installer.XXXXXX)"
    cp "$PRIV_SRC" "$STAGE/privileged-install.sh"
    cp "$POLICY_SRC" "$STAGE/policy.policy"
    chmod 644 "$STAGE"/*

    pkexec bash -c "
        install -Dm755 '${STAGE}/privileged-install.sh' '${PRIV_DST}'
        install -Dm644 '${STAGE}/policy.policy' '${POLICY_DST}'
    "
    STATUS=$?

    rm -rf "$STAGE"

    if [[ $STATUS -ne 0 ]]; then
        echo "Failed to install privileged components (exit $STATUS)." >&2
        echo "The app will still open, but Install Driver will not work" >&2
        echo "until this succeeds. Try running the AppImage again." >&2
    fi
fi

export PATH="${HERE}/usr/bin:$PATH"
export XDG_DATA_DIRS="${HERE}/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "${HERE}/usr/bin/nvidia-driver-installer" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

echo "==> Downloading linuxdeploy and GTK plugin…"
wget -q -c "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage" \
    -O linuxdeploy-x86_64.AppImage
wget -q -c "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh"
chmod +x linuxdeploy-x86_64.AppImage linuxdeploy-plugin-gtk.sh

echo "==> Building AppImage…"
APPIMAGE_EXTRACT_AND_RUN=1 \
VERSION="$VERSION" \
UPDATE_INFORMATION="gh-releases-zsync|labj1987|NVI|latest|nvidia-driver-installer-*-x86_64.AppImage.zsync" \
    ./linuxdeploy-x86_64.AppImage \
    --appdir "$APPDIR" \
    --plugin gtk \
    --output appimage \
    --icon-file "data/nvidia-driver-installer-256.png" \
    --desktop-file "$APPDIR/nvidia-driver-installer.desktop"

OUTFILE=$(ls *.AppImage 2>/dev/null | head -1)
if [[ -n "$OUTFILE" ]]; then
    mv "$OUTFILE" "nvidia-driver-installer-${VERSION}-x86_64.AppImage"
    chmod +x "nvidia-driver-installer-${VERSION}-x86_64.AppImage"
    if [[ -f "${OUTFILE}.zsync" ]]; then
        mv "${OUTFILE}.zsync" "nvidia-driver-installer-${VERSION}-x86_64.AppImage.zsync"
    fi
    echo ""
    echo "==> Done: nvidia-driver-installer-${VERSION}-x86_64.AppImage"
    echo ""
    echo "Users can run it with:"
    echo "  chmod +x nvidia-driver-installer-${VERSION}-x86_64.AppImage"
    echo "  ./nvidia-driver-installer-${VERSION}-x86_64.AppImage"
fi
