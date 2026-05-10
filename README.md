# Showcase

Showcase turns a jailbroken cellular iPad into a software wireless CarPlay receiver. The iPhone pairs through Settings, joins the iPad hotspot, sends the encrypted CarPlay video stream, and receives touch input from the iPad.

The first public build targets rootful iOS 12. The tested receiver is an iPad Air 1 cellular on iOS 12.5.8.

## Install

Add the package source in Sileo, Cydia, or Zebra.

```text
https://aminerostane.com/repo
```

Then install `Showcase`.

The install guide and protocol write-up live here.

https://aminerostane.com/articles/showcase

## Requirements

| Item | Requirement |
| --- | --- |
| iPad | Cellular iPad with Personal Hotspot |
| Tested receiver | iPad Air 1 cellular, A1475, iPad4,2 |
| Tested firmware | iOS 12.5.8 |
| Jailbreak | Rootful |
| Runtime packages | `libssl3`, `uikittools` |

The package bundles `BTdaemon`, `libBTstack.dylib`, and the BTstack launch daemon needed for `/tmp/BTstack`. It conflicts with the old `ch.ringwald.btstack` package to avoid file ownership collisions.

## What Works

- Wireless CarPlay discovery over Bluetooth and AirPlay/mDNS.
- BTstack takeover while the receiver runs.
- iAP2 link setup, identification, BAA authentication, Wi-Fi handoff, and EAP session setup.
- AirPlay pair-setup, pair-verify, auth-setup, RTSP control, timing, event channel, and screen stream setup.
- H.264 screen stream decryption with ChaCha20-Poly1305.
- Single-finger touch forwarding over the encrypted event channel.

## Source Layout

```text
source/       app, Bluetooth helper, AirPlay helper, pairing code
packaging/    Debian control files, depictions, package scripts
icon/         app icons
```

## Build From Source

Showcase builds on the jailbroken iPad. The build script expects SSH access through a local forwarded port.

```sh
iproxy 2222 <ipad-sshd-port>
IPAD_PORT=2222 IPAD_PASS=alpine ./build_and_install.sh
```

For a jailbreak SSH daemon on port 22, run this command.

```sh
iproxy 2222 22
```

The script compiles the three binaries on-device, signs them with `ldid`, installs `/Applications/Showcase.app`, and refreshes SpringBoard.

## Build The Deb

Build and test the app on the iPad first.

```sh
cd packaging
./scripts/fetch-installed-app.sh
./scripts/build-rootful-deb.sh
./scripts/generate-apt-repo.py repo
```

The `.deb` lands in `packaging/build/`. The APT repository lands in `packaging/repo/`.

For GitHub Releases, upload the `.deb` from `packaging/build/` after you rebuild the package. The first public asset should be `com.rostane.showcase_1.0~beta1-1_iphoneos-arm.deb` under a `v1.0-beta1` release.

For Sileo, Cydia, and Zebra, publish the generated `packaging/repo/` contents to the web path that serves `https://aminerostane.com/repo`.

## Logs

```text
/var/mobile/Library/Showcase/logs/showcase.log
/var/mobile/Library/Showcase/logs/btdaemon.log
/var/mobile/Library/Showcase/logs/carplay_bt.log
/var/mobile/Library/Showcase/logs/carplay_services.log
```

Check logs before posting them in public issues. Logs can include device names, hotspot names, network details, and pairing traces.

## License

GPL-3.0-or-later. The pairing code includes work adapted from UxPlay and csrp. Binary packages bundle BTstack runtime files from the historical `ch.ringwald.btstack` jailbreak package by Matthias Ringwald.
