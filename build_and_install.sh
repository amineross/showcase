#!/bin/bash
# build_and_install.sh — compile, sign, and install Showcase.app on the iPad.
#
# Prerequisites:
#   - iproxy running:           iproxy <local-port> <ipad-sshd-port>
#   - sshpass installed:        brew install hudochenkov/sshpass/sshpass
#   - SDK available locally:    one of:
#                                 ./iPhoneOS10.3.sdk.tar
#                                 ../iPhoneOS10.3.sdk.tar
#                                 /tmp/iPhoneOS10.3.sdk.tar
#                                 /tmp/os/iOS-SDK/iPhoneOS10.3.sdk    (will tar)
#   - iPad jailbroken with: clang, ldid, libcrypto.dylib

set -e

SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa,ssh-dss -o PubkeyAcceptedAlgorithms=+ssh-rsa"
IPAD_HOST="${IPAD_HOST:-localhost}"
IPAD_PORT="${IPAD_PORT:-2222}"
IPAD_USER="${IPAD_USER:-root}"
IPAD_PASS="${IPAD_PASS:-alpine}"
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/source"
ICON="$DIR/icon/generated"
SDK_REMOTE="/tmp/iPhoneOS10.3.sdk"
BTSTACK_DYLIB="$DIR/packaging/payload/usr/lib/libBTstack.dylib"

ssh_cmd() { sshpass -p "$IPAD_PASS" ssh $SSHOPTS -p "$IPAD_PORT" "$IPAD_USER@$IPAD_HOST" "$@"; }
scp_cmd() { sshpass -p "$IPAD_PASS" scp $SSHOPTS -P "$IPAD_PORT" "$@"; }

echo "═══════════════════════════════════════════════════════════"
echo "Showcase — build & install"
echo "═══════════════════════════════════════════════════════════"

# ── Step 0: SDK on iPad? ─────────────────────────────────────────
echo ""
echo "[0/7] SDK check"
if ssh_cmd "test -d $SDK_REMOTE" 2>/dev/null; then
    echo "       SDK already on iPad at $SDK_REMOTE"
else
    echo "       SDK missing on iPad — preparing tarball..."
    SDK_TAR=""
    for cand in "$DIR/iPhoneOS10.3.sdk.tar" "$DIR/../iPhoneOS10.3.sdk.tar" "/tmp/iPhoneOS10.3.sdk.tar"; do
        if [ -f "$cand" ] && [ "$(stat -f %z "$cand")" -gt 1000000 ]; then
            SDK_TAR="$cand"; break
        fi
    done
    if [ -z "$SDK_TAR" ]; then
        for tree in "/tmp/os/iOS-SDK/iPhoneOS10.3.sdk" "$DIR/iPhoneOS10.3.sdk" "$DIR/../iPhoneOS10.3.sdk"; do
            if [ -d "$tree" ]; then
                echo "       found SDK tree at $tree, tarring..."
                parent="$(dirname "$tree")"
                base="$(basename "$tree")"
                (cd "$parent" && tar cf /tmp/iPhoneOS10.3.sdk.tar "$base")
                SDK_TAR="/tmp/iPhoneOS10.3.sdk.tar"; break
            fi
        done
    fi
    if [ -z "$SDK_TAR" ]; then
        echo "       ERROR: cannot find SDK locally."
        exit 1
    fi
    echo "       uploading $SDK_TAR (~30s)"
    scp_cmd "$SDK_TAR" "$IPAD_USER@$IPAD_HOST:/tmp/"
    echo "       extracting on iPad..."
    ssh_cmd "cd /tmp && tar xf iPhoneOS10.3.sdk.tar && test -d $SDK_REMOTE && echo OK"
fi

# ── Step 1: Send sources + entitlements + plist ───────────────────
echo ""
echo "[1/7] Sending sources + icons"
scp_cmd "$SRC/Showcase.m" \
        "$SRC/carplay_bt.m" \
        "$SRC/carplay_services.m" \
        "$SRC/carplay_pair.c" \
        "$SRC/carplay_pair.h" \
        "$SRC/Info.plist" \
        "$SRC/ent_app.xml" \
        "$SRC/ent_bt.xml" \
        "$SRC/ent_svc.xml" \
        "$ICON"/*.png \
        "$IPAD_USER@$IPAD_HOST:/tmp/"

BTSTACK_LINK="/usr/lib/libBTstack.dylib"
if [ -f "$BTSTACK_DYLIB" ]; then
    scp_cmd "$BTSTACK_DYLIB" "$IPAD_USER@$IPAD_HOST:/tmp/libBTstack.dylib"
    BTSTACK_LINK="/tmp/libBTstack.dylib"
elif ! ssh_cmd "test -f /usr/lib/libBTstack.dylib" 2>/dev/null; then
    echo "       ERROR: missing BTstack link library."
    echo "       Install BTstack on the build device, or place libBTstack.dylib at $BTSTACK_DYLIB."
    exit 1
else
    echo "       using /usr/lib/libBTstack.dylib from the iPad"
fi

# ── Step 2: Compile Showcase (UI + orchestrator) ──────────────────
echo ""
echo "[2/7] Compiling Showcase"
# Note: -Wl,-undefined,dynamic_lookup needed because the iPad-side ld treats
# the SDK's .tbd stubs as 'out of sync' for libSystem (memset/strcmp etc).
# Symbols resolve at runtime via dyld through libSystem.B.dylib (linked via Foundation).
ssh_cmd "clang -fobjc-arc -isysroot $SDK_REMOTE \
    -o /tmp/Showcase /tmp/Showcase.m \
    -framework UIKit -framework AVFoundation \
    -framework CoreMedia -framework Foundation \
    -Wl,-undefined,dynamic_lookup 2>&1" || { echo "FAIL"; exit 1; }
echo "       OK"

# ── Step 3: Compile carplay_bt ────────────────────────────────────
echo ""
echo "[3/7] Compiling carplay_bt"
ssh_cmd "clang -fobjc-arc -isysroot $SDK_REMOTE \
    -o /tmp/carplay_bt /tmp/carplay_bt.m \
    $BTSTACK_LINK \
    -framework Foundation -framework Security \
    -Wl,-undefined,dynamic_lookup 2>&1" || { echo "FAIL"; exit 1; }
echo "       OK"

# ── Step 4: Compile carplay_services ──────────────────────────────
echo ""
echo "[4/7] Compiling carplay_services"
ssh_cmd "clang -fobjc-arc -isysroot $SDK_REMOTE -I/usr/include \
    -o /tmp/carplay_services /tmp/carplay_services.m /tmp/carplay_pair.c \
    -framework Foundation -framework Security \
    /usr/lib/libcrypto.dylib \
    -Wl,-undefined,dynamic_lookup 2>&1" \
    || ssh_cmd "clang -fobjc-arc -isysroot $SDK_REMOTE -I/usr/include -L/usr/lib \
        -o /tmp/carplay_services /tmp/carplay_services.m /tmp/carplay_pair.c \
        -framework Foundation -framework Security -lcrypto \
        -Wl,-undefined,dynamic_lookup 2>&1" \
    || { echo "FAIL"; exit 1; }
echo "       OK"

# ── Step 5: Assemble Showcase.app ─────────────────────────────────
echo ""
echo "[5/7] Assembling Showcase.app + signing"
ssh_cmd "
set -e
APP=/Applications/Showcase.app
STAGE=/tmp/Showcase.app.new
rm -rf \$STAGE
mkdir -p \$STAGE
cp /tmp/Showcase         \$STAGE/Showcase
cp /tmp/carplay_bt       \$STAGE/carplay_bt
cp /tmp/carplay_services \$STAGE/carplay_services
cp /tmp/Info.plist       \$STAGE/Info.plist
cp /tmp/Icon*.png        \$STAGE/

# Sign each binary with its own entitlements
ldid -S/tmp/ent_app.xml \$STAGE/Showcase
ldid -S/tmp/ent_bt.xml  \$STAGE/carplay_bt
ldid -S/tmp/ent_svc.xml \$STAGE/carplay_services

# Clean swap
rm -rf \$APP
mv \$STAGE \$APP

chmod +x \$APP/Showcase \$APP/carplay_bt \$APP/carplay_services

# Setuid root so app can launchctl + posix_spawn(BTdaemon).
chown root:wheel \$APP/Showcase \$APP/carplay_bt \$APP/carplay_services
chmod 4755 \$APP/Showcase
chmod 4755 \$APP/carplay_bt
chmod 4755 \$APP/carplay_services

# Refresh SpringBoard
/usr/bin/uicache --path \$APP

echo 'INSTALLED'
ls -la \$APP/
" || { echo "FAIL"; exit 1; }

# ── Step 6: Verify ────────────────────────────────────────────────
echo ""
echo "[6/7] Verify"
ssh_cmd "
echo '=== /Applications/Showcase.app ==='
ls -la /Applications/Showcase.app/
echo ''
echo '=== Entitlements (Showcase) ==='
ldid -e /Applications/Showcase.app/Showcase 2>&1 | head -10
"

# ── Step 7: Done ──────────────────────────────────────────────────
echo ""
echo "[7/7] Logs available at /var/mobile/Library/Showcase/logs/"
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "DONE — Tap Showcase on the home screen to run."
echo "═══════════════════════════════════════════════════════════"
