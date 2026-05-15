#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
CONTROL="$ROOT/control/control"
PAYLOAD="$ROOT/payload"
PAYLOAD_APP="$ROOT/payload/Applications/Showcase.app"
BTSTACK_DYLIB="$PAYLOAD/usr/lib/libBTstack.dylib"
BUILD="$ROOT/build"
REMOTE_BASE="${REMOTE_BASE:-/tmp/showcase-deb-build}"
SDK_REMOTE="${SDK_REMOTE:-/tmp/iPhoneOS10.3.sdk}"

IPAD_HOST="${IPAD_HOST:-localhost}"
IPAD_PORT="${IPAD_PORT:-2222}"
IPAD_USER="${IPAD_USER:-root}"
IPAD_PASS="${IPAD_PASS:-alpine}"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o NumberOfPasswordPrompts=1
  -p "$IPAD_PORT"
)

SCP_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o NumberOfPasswordPrompts=1
  -P "$IPAD_PORT"
)

field() {
  awk -F': ' -v key="$1" '$1 == key { print $2; exit }' "$CONTROL"
}

need_file() {
  if [ ! -f "$1" ]; then
    echo "Missing file: $1"
    exit 1
  fi
}

PKG="$(field Package)"
VER="$(field Version)"
ARCH="$(field Architecture)"
DEB_NAME="${PKG}_${VER}_${ARCH}.deb"

if [ ! -d "$PAYLOAD_APP" ]; then
  echo "Missing payload: $PAYLOAD_APP"
  echo "Run scripts/fetch-installed-app.sh first."
  exit 1
fi

need_file "$BTSTACK_DYLIB"
need_file "$REPO_ROOT/source/Showcase.m"
need_file "$REPO_ROOT/source/carplay_bt.m"
need_file "$REPO_ROOT/source/carplay_services.m"
need_file "$REPO_ROOT/source/carplay_pair.c"
need_file "$REPO_ROOT/source/carplay_pair.h"
need_file "$REPO_ROOT/source/Info.plist"
need_file "$REPO_ROOT/source/ent_app.xml"
need_file "$REPO_ROOT/source/ent_bt.xml"
need_file "$REPO_ROOT/source/ent_svc.xml"

sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" "
set -e
test -d '$SDK_REMOTE'
command -v clang >/dev/null
command -v ldid >/dev/null
command -v dpkg-deb >/dev/null
"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/showcase-rootful.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/send" "$WORK/rootfs" "$WORK/rootfs/DEBIAN" "$BUILD" "$ROOT/repo/debs"

cp "$REPO_ROOT/source/Showcase.m" \
   "$REPO_ROOT/source/carplay_bt.m" \
   "$REPO_ROOT/source/carplay_services.m" \
   "$REPO_ROOT/source/carplay_pair.c" \
   "$REPO_ROOT/source/carplay_pair.h" \
   "$REPO_ROOT/source/Info.plist" \
   "$REPO_ROOT/source/ent_app.xml" \
   "$REPO_ROOT/source/ent_bt.xml" \
   "$REPO_ROOT/source/ent_svc.xml" \
   "$WORK/send/"
cp "$BTSTACK_DYLIB" "$WORK/send/libBTstack.dylib"

sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" \
  "rm -rf '$REMOTE_BASE' && mkdir -p '$REMOTE_BASE'"

sshpass -p "$IPAD_PASS" scp "${SCP_OPTS[@]}" \
  "$WORK/send/"* \
  "$IPAD_USER@$IPAD_HOST:$REMOTE_BASE/"

sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" "
set -e
cd '$REMOTE_BASE'

clang -fobjc-arc -isysroot '$SDK_REMOTE' \
    -o Showcase Showcase.m \
    -framework UIKit -framework AVFoundation \
    -framework CoreMedia -framework Foundation \
    -Wl,-undefined,dynamic_lookup

clang -fobjc-arc -isysroot '$SDK_REMOTE' \
    -o carplay_bt carplay_bt.m \
    ./libBTstack.dylib \
    -framework Foundation -framework Security \
    -Wl,-undefined,dynamic_lookup

clang -fobjc-arc -isysroot '$SDK_REMOTE' -I/usr/include \
    -o carplay_services carplay_services.m carplay_pair.c \
    -framework Foundation -framework Security \
    /usr/lib/libcrypto.dylib \
    -Wl,-undefined,dynamic_lookup \
    || clang -fobjc-arc -isysroot '$SDK_REMOTE' -I/usr/include -L/usr/lib \
        -o carplay_services carplay_services.m carplay_pair.c \
        -framework Foundation -framework Security -lcrypto \
        -Wl,-undefined,dynamic_lookup
"

cp -R "$PAYLOAD"/. "$WORK/rootfs"/
for bin in Showcase carplay_bt carplay_services; do
  sshpass -p "$IPAD_PASS" scp "${SCP_OPTS[@]}" \
    "$IPAD_USER@$IPAD_HOST:$REMOTE_BASE/$bin" \
    "$WORK/rootfs/Applications/Showcase.app/$bin"
done
cp "$REPO_ROOT/source/Info.plist" "$WORK/rootfs/Applications/Showcase.app/Info.plist"

cp "$ROOT/control/control" "$WORK/rootfs/DEBIAN/control"
cp "$ROOT/control/postinst" "$WORK/rootfs/DEBIAN/postinst"
cp "$ROOT/control/prerm" "$WORK/rootfs/DEBIAN/prerm"
cp "$ROOT/control/postrm" "$WORK/rootfs/DEBIAN/postrm"
cp "$REPO_ROOT/source/ent_app.xml" "$WORK/rootfs/DEBIAN/ent_app.xml"
cp "$REPO_ROOT/source/ent_bt.xml" "$WORK/rootfs/DEBIAN/ent_bt.xml"
cp "$REPO_ROOT/source/ent_svc.xml" "$WORK/rootfs/DEBIAN/ent_svc.xml"

find "$WORK/rootfs" -name '.DS_Store' -delete
find "$WORK/rootfs" -name '._*' -delete
xattr -cr "$WORK/rootfs" 2>/dev/null || true

COPYFILE_DISABLE=1 tar --format ustar -C "$WORK" -cf "$WORK/rootfs.tar" rootfs

sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" \
  "rm -rf '$REMOTE_BASE' && mkdir -p '$REMOTE_BASE'"

sshpass -p "$IPAD_PASS" scp "${SCP_OPTS[@]}" \
  "$WORK/rootfs.tar" \
  "$IPAD_USER@$IPAD_HOST:$REMOTE_BASE/rootfs.tar"

sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "$IPAD_USER@$IPAD_HOST" "
set -e
cd '$REMOTE_BASE'
tar xf rootfs.tar
cd rootfs
find . -name '._*' -delete
find . -name '.DS_Store' -delete

chown root:wheel .
chown -R root:wheel Applications usr Library DEBIAN
chmod 0755 . Applications Applications/Showcase.app usr usr/bin usr/lib Library Library/LaunchDaemons
chmod 0644 Applications/Showcase.app/Info.plist Applications/Showcase.app/Icon*.png
chmod 4755 Applications/Showcase.app/Showcase Applications/Showcase.app/carplay_bt Applications/Showcase.app/carplay_services
chmod 0755 usr/bin/BTdaemon usr/lib/libBTstack.dylib
chmod 0644 Library/LaunchDaemons/ch.ringwald.BTstack.plist
chmod 0755 DEBIAN/postinst DEBIAN/prerm DEBIAN/postrm
chmod 0644 DEBIAN/control

ldid -SDEBIAN/ent_app.xml Applications/Showcase.app/Showcase
ldid -SDEBIAN/ent_bt.xml  Applications/Showcase.app/carplay_bt
ldid -SDEBIAN/ent_svc.xml Applications/Showcase.app/carplay_services
rm -f DEBIAN/ent_app.xml DEBIAN/ent_bt.xml DEBIAN/ent_svc.xml

find . -path ./DEBIAN -prune -o -type f -exec md5sum {} \\; > DEBIAN/md5sums
chmod 0644 DEBIAN/md5sums

dpkg-deb -Zgzip -z9 -b . '../$DEB_NAME'
dpkg-deb -I '../$DEB_NAME'
dpkg-deb -c '../$DEB_NAME' | sed -n '1,80p'
"

sshpass -p "$IPAD_PASS" scp "${SCP_OPTS[@]}" \
  "$IPAD_USER@$IPAD_HOST:$REMOTE_BASE/$DEB_NAME" \
  "$BUILD/$DEB_NAME"

cp "$BUILD/$DEB_NAME" "$ROOT/repo/debs/$DEB_NAME"

echo "Built $BUILD/$DEB_NAME"
echo "Copied repo payload to $ROOT/repo/debs/$DEB_NAME"
