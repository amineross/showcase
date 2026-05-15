#!/bin/zsh
set -e
SCRIPT_DIR=${0:a:h}
ROOT=${BTSTACK_ROOT:-$SCRIPT_DIR}
SDK=${SDK:-/var/jb/usr/share/SDKs/iPhoneOS.sdk}
ENT=${ENT:-/var/jb/usr/share/showcase/ent_btdaemon.xml}
OUT=${OUT:-/tmp/BTdaemon}
SRC_C=(
  $ROOT/src/ad_parser.c $ROOT/src/btstack_linked_list.c $ROOT/src/btstack_memory.c
  $ROOT/src/btstack_memory_pool.c $ROOT/src/btstack_run_loop.c $ROOT/src/btstack_run_loop_base.c
  $ROOT/src/btstack_tlv.c $ROOT/src/btstack_util.c $ROOT/src/hci.c $ROOT/src/hci_cmd.c
  $ROOT/src/hci_dump.c $ROOT/src/l2cap.c $ROOT/src/l2cap_signaling.c
  $ROOT/src/classic/rfcomm.c $ROOT/src/classic/sdp_client.c $ROOT/src/classic/sdp_client_rfcomm.c
  $ROOT/src/classic/sdp_server.c $ROOT/src/classic/sdp_util.c $ROOT/src/classic/spp_server.c
  $ROOT/src/classic/btstack_link_key_db_tlv.c
  $ROOT/platform/daemon/src/btstack.c $ROOT/platform/daemon/src/daemon.c
  $ROOT/platform/daemon/src/daemon_cmds.c $ROOT/platform/daemon/src/socket_connection.c
  $ROOT/platform/posix/btstack_run_loop_posix.c $ROOT/platform/posix/btstack_tlv_posix.c
  $ROOT/port/ios/src/hci_transport_h4_iphone.c $ROOT/port/ios/SpringBoardAccess/SpringBoardAccess.c
)
SRC_M=(
  $ROOT/platform/corefoundation/btstack_device_name_db_corefoundation.m
  $ROOT/platform/corefoundation/btstack_link_key_db_corefoundation.m
  $ROOT/platform/corefoundation/btstack_run_loop_corefoundation.m
  $ROOT/platform/corefoundation/rfcomm_service_db_corefoundation.m
  $ROOT/port/ios/src/btstack_control_iphone.m $ROOT/port/ios/src/platform_iphone.m
)
CFLAGS=( -isysroot $SDK -arch arm64 -mios-version-min=14.0 -fno-objc-arc
  -I$ROOT/port/ios -I$ROOT/port/ios/src -I$ROOT/platform/daemon/src
  -I$ROOT/platform/posix -I$ROOT/platform/corefoundation -I$ROOT/src
  -O2 -Wno-deprecated-declarations -Wno-deprecated-non-prototype
  -Wno-incompatible-pointer-types -Wno-pointer-sign -Wno-unused-command-line-argument )
LDFLAGS=( -framework Foundation -framework CoreFoundation -framework IOKit -Wl,-undefined,dynamic_lookup )
echo "[1/3] Compiling..."
clang ${CFLAGS[@]} ${SRC_C[@]} ${SRC_M[@]} ${LDFLAGS[@]} -o $OUT 2>&1 | tail -20
test -f $OUT
ldid -S$ENT $OUT
echo "OK -> $OUT"
