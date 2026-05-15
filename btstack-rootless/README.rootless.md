# BTstack Rootless Notes

This directory carries the BTstack v1.1 iOS daemon source used by Showcase for rootless jailbreaks.

The bundled daemon comes from the historical iOS BTstack port by Matthias Ringwald, with a small CarPlay-focused patch set for Dopamine and palera1n rootless devices.

## What Changed

- `src/hci.c` marks an encrypted classic BR/EDR link as authenticated when the controller reports nonzero encryption. Older iPads and iPhones can complete SSP without BR/EDR Secure Connections, so the original AES-CCM-only check blocked RFCOMM.
- `platform/daemon/src/daemon.c` routes `RFCOMM_DATA_PACKET` through `connection_for_rfcomm_cid`.
- `platform/daemon/src/daemon.c` registers the incoming RFCOMM cid immediately after `RFCOMM_ACCEPT_CONNECTION`.
- BLE-only TLV setup calls in `daemon.c` sit behind `#ifdef ENABLE_BLE`, which lets the classic-only iOS daemon link.
- `build_btdaemon.sh` builds the arm64 daemon against the Procursus SDK and signs it with the Showcase BTdaemon entitlement file.

## Build On Device

Copy this directory to the jailbroken device and run this command.

```sh
cd btstack-rootless
SDK=/var/jb/usr/share/SDKs/iPhoneOS.sdk \
ENT=/var/jb/usr/share/showcase/ent_btdaemon.xml \
OUT=/tmp/BTdaemon \
./build_btdaemon.sh
```

The script defaults to the paths above, so the environment variables only matter when you keep the SDK, entitlements, or output somewhere else.

## Showcase Packaging

Showcase packages the compiled daemon in this path.

```text
packaging/payload-rootless/usr/bin/BTdaemon
```

The app starts it through this launch daemon.

```text
/var/jb/Library/LaunchDaemons/ch.ringwald.BTstack.plist
```

The daemon owns `/tmp/BTstack`. The CarPlay Bluetooth helper connects to that socket and drives the iAP2 Bluetooth path.
