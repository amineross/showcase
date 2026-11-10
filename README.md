# Showcase

## Updates

This repository contains the Showcase source. Install the packaged tweak from the Rostane source in Sileo.

```text
https://aminerostane.com/repo
```

Beta 5-3

- Works with iPhones on iOS 27. Thanks @techdepanneur.
- Needs internet once, then works offline for about a year.
- Bluetooth starts about 7 seconds sooner.
- Network Capture waits for the hotspot instead of saying tcpdump is missing.
- Keeps settings that iOS forgot after a relaunch.
- Prioritize Quality goes back off on iPad Air 1 and iPad mini 2 and 3.
- Speaks Turkish. Thanks @inckerem.
- Send Logs includes Share's state and the Wi-Fi log.

Beta 5-2

- Turns on Prioritize Quality once for everyone, including existing setups. Turn it off in Settings > Display and it stays off.
- Adds a star button on the home screen that links to this repository.
- Adds anonymous usage reporting, on by default. Settings > Anonymous Usage turns it off or turns off single items. See [Anonymous Usage](#anonymous-usage).

Beta 5

- Adds a resolution picker and a 30 or 60 fps choice in Settings > Display. The resolutions follow your screen's shape, like on a Mac.
- Adds Prioritize Quality and Prioritize Performance. Quality streams the largest resolution at 60 fps; Performance is the old Prefer Smooth Video.
- Speaks French, Spanish, Simplified Chinese and Japanese. Showcase follows your device's language, and Settings > Language lets you pick another.
- Ships a separate Showcase for Taurine package for Taurine on iOS 14.

Beta 4-3

- Fixes the false hotspot name warning on iOS 16 and newer.

Beta 4-2

- Reconnects to your iPhone by itself, like a car. Open Showcase and CarPlay comes back without touching the iPhone.
- Starts CarPlay when you open Showcase. You can turn this off in Settings.
- Stops cleanly and waits for your iPhone when it leaves or turns off Wi-Fi.
- Rootless: keeps the Bluetooth pairing after a reboot.
- Relaunching no longer asks for internet, Try Again works, and Showcase retries when the network comes back.
- Opens without the long black screen.
- Warns when the hotspot name doesn't match the device name.

Beta 4

- Starts Personal Hotspot by itself, and asks you to turn it on in Settings when iOS refuses.
- Lets you pick where sound plays by tapping the receiver or the CarPlay sender on the Sound page.
- Shortens the connection steps and drops the small explanation text.
- Returns to CarPlay when you tap anywhere on the dimmed controls screen.
- Removes the 5 GHz hotspot option. The hotspot uses the band iOS chooses.
- Reads every version string from the `VERSION` file.

Showcase turns an older jailbroken Apple device into a software wireless CarPlay receiver. The iPhone pairs through Settings, joins the receiver's hotspot, sends the encrypted CarPlay video stream, and receives touch input from the receiver.

Showcase ships in rootful and rootless package layouts. Both use iOS 12 as the deployment minimum.

## Install

Add the package source in Sileo, Cydia, or Zebra.

```text
https://aminerostane.com/repo
```

Then install `Showcase`.

On Taurine (iOS 14), install `Showcase for Taurine` instead. It starts Bluetooth in the order Taurine needs, waits longer for the controller and adds BTQuiet, which slows Bluetooth clients' reconnects while Showcase owns the controller. It replaces the regular package.

Install guide and protocol write-up

https://aminerostane.com/articles/showcase

## Requirements

| Item | Requirement |
| --- | --- |
| Receiver | Jailbroken iPhone or iPad with Personal Hotspot |
| Tested rootful receiver | iPad Air 1, A1475, iPad4,2, iOS 12.5.8, checkra1n |
| Tested rootless receiver | iPhone 7, iPhone9,3, iOS 15.8.4, Dopamine rootless |
| Runtime packages | Rootful uses `uikittools`; rootless uses `uikittools` and `ldid` |

Sileo, Cydia, and Zebra install runtime packages through normal APT dependency resolution. Manual dependency installation is only needed when sideloading a `.deb` with `dpkg -i`.

The package bundles `BTdaemon`, `libBTstack.dylib`, and the BTstack launch daemon needed for `/tmp/BTstack`. It conflicts with the old `ch.ringwald.btstack` package to avoid file ownership collisions.

## What Works

- Wireless CarPlay discovery over Bluetooth and AirPlay/mDNS.
- BTstack takeover while the receiver runs.
- iAP2 link setup, identification, BAA authentication, Wi-Fi handoff, and EAP session setup.
- AirPlay pair-setup, pair-verify, auth-setup, RTSP control, timing, event channel, and screen stream setup.
- H.264 screen stream decryption with ChaCha20-Poly1305.
- Single-finger touch forwarding over the encrypted event channel.
- BAA certificate preheating while the receiver still has internet access.
- Stream sizing derived from the receiver's native aspect ratio, memory, processor count, and decode budget.
- Sender-timeline H.264 presentation with an adaptive jitter budget and stale-frame recovery after transport stalls.
- Stream telemetry for arrival rate, bitrate, frame gaps, presentation delay, and UI enqueue time.
- Receiver audio for navigation, calls, radio, Apple Music, and third-party media apps.
- A named vehicle app with the Showcase icon and a clean CarPlay sidebar.
- Three-finger controls that dim the video and block CarPlay input until you tap to return.
- Persistent controller pairing, CarPlay screen-resource handoff, and fresh-keyframe recovery after backgrounding.
- A Bluetooth compatibility report when BTstack cannot control the receiver hardware.

Showcase embeds Monocypher and LibTomMath for CarPlay cryptography. Users no longer need an OpenSSL package or repository.

## Video Quality

Settings > Display sets the CarPlay stream. Reconnect CarPlay after a change.

- **Resolution** lists sizes that match the screen's aspect ratio, like the scaled resolutions macOS offers, up to 1920 pixels wide and 1080p worth of pixels. **Default** is sized from the receiver's memory and processor count.
- **Frame Rate** is 30 or 60 fps. The default is 60, or 30 on receivers with HSIC Wi-Fi such as the iPad Air, which drop large bursts. About > Wi-Fi Bus shows yours.
- **Prioritize Quality** uses the largest listed resolution at 60 fps.
- **Prioritize Performance** uses about half the default's pixels at 30 fps, which roughly halves what each frame puts on the hotspot. It replaces Prefer Smooth Video and keeps that setting.

Either priority grays out Resolution and Frame Rate; only one can be on. The About page and the `display profile` log line show what Showcase requested. The iPhone still decides the H.264 bitrate.

The sharper stream started with [@edouaz](https://github.com/edouaz) in [#26](https://github.com/amineross/showcase/pull/26), tested on an iPad Air (iPad4,1) on iOS 12.5.7. `tests/test_display_profile.py` compiles the production selector and checks every mode across 576 receiver profiles.

## Anonymous Usage

Showcase reports how many people use it and on what, so I know which devices and jailbreaks to support. Settings > Anonymous Usage lists every item with the value Showcase sends, and turns each one off, or all of them.

| Item | Example |
| --- | --- |
| `id` | `bedab7dc-d7d5-42e8-9ecb-6132d381e320`, a random UUID made on first use. It isn't derived from the device |
| `model` | `iPad4,2` |
| `ios` | `12.5.8` |
| `jailbreak` | `amethyst`, guessed from the jailbreak's marker file, or `unknown` |
| `version` | `1.0~beta5-2` |
| `package` | `rootful`, `rootless` or `taurine` |
| `language` | `fr` |
| `country` | `true` asks the server to store the country Cloudflare sees for the request |

Showcase posts these as JSON to `https://aminerostane.com/api/ping` 10 seconds after launch, only when the items differ from the last report or 30 days have passed. If the request fails, Showcase drops it and tries again next launch; nothing shows on screen.

The endpoint is a Cloudflare Worker, `telemetry/worker.js`, with a D1 database. It keeps one row per `id` with first and last report dates and stores no IP address. An item turned off is cleared from that row on the next report. The app side is `send_anonymous_usage()` in `source/Showcase.m`.

## Languages

Showcase speaks English, French, Spanish, Simplified Chinese, Japanese and Turkish. It follows the device's preferred languages; Settings > Language picks another one. iOS places and features use Apple's own names in each language.

Translations live in `tools/localization/translations.py`. After changing a string or a translation, run `tools/localization/generate.py` to rewrite `source/Localizations/*.lproj`, then `tests/test_localization.py`.

## Source Layout

```text
source/       app, Bluetooth helper, AirPlay helper, pairing code
btstack-rootless/
              patched BTstack v1.1 iOS daemon source used by the rootless package
source/Localizations/
              generated translations
packaging/    Debian control files, depictions, package scripts
tweak/        BTQuiet, shipped only in the Taurine package
telemetry/    Cloudflare Worker and schema behind anonymous usage
tools/localization/
              translation table and generator
icon/         app icons
```

## Build From Source

Showcase builds on the jailbroken receiver. The build script expects SSH access through a local forwarded port and pins the deployment target to iOS 12.0.

```sh
iproxy 2222 <ipad-sshd-port>
IPAD_PORT=2222 IPAD_PASS=alpine ./build_and_install.sh
```

For a jailbreak SSH daemon on port 22, run this command.

```sh
iproxy 2222 22
```

The script compiles the three binaries on-device, signs them with `ldid`, installs the rootful app under `/Applications`, and refreshes SpringBoard. Use the package scripts below for rootless builds.

## Build The Deb

Build and test the app on the iPad first.

```sh
cd packaging
./scripts/fetch-installed-app.sh
./scripts/build-rootful-deb.sh
./scripts/build-rootless-deb.sh
./scripts/build-taurine-deb.sh
./scripts/generate-apt-repo.py repo
```

`build-taurine-deb.sh` builds `com.rostane.showcase-taurine` on the rootful device: Showcase compiled with `SHOWCASE_TAURINE`, the BTdaemon from `btstack-rootless/` and BTQuiet. It depends on iOS 14 and conflicts with the regular package, so other jailbreaks never get it. `VARIANT=taurine ./build_and_install.sh` installs the same app for testing.

The `.deb` files land in `packaging/build/`. The APT repository lands in `packaging/repo/`.

For GitHub Releases, upload both `.deb` files from `packaging/build/` after you rebuild the packages. The rootful asset ends in `iphoneos-arm.deb`; the rootless asset ends in `iphoneos-arm64.deb`.

For Sileo, Cydia, and Zebra, publish the generated `packaging/repo/` contents to the web path that serves `https://aminerostane.com/repo`.

## Logs

```text
/var/mobile/Library/Showcase/logs/app.log
/var/mobile/Library/Showcase/logs/baa_broker.log
/var/mobile/Library/Showcase/logs/btdaemon.log
/var/mobile/Library/Showcase/logs/carplay_bt.log
/var/mobile/Library/Showcase/logs/carplay_services.log
```

Check logs before posting them in public issues. Logs can include device names, hotspot names, network details, and pairing traces.

## BTstack Rootless Source

The rootless package bundles a patched BTstack daemon. Its source lives in `btstack-rootless/`.

The patch set fixes classic BR/EDR authentication state, incoming RFCOMM cid registration, RFCOMM data routing, and classic-only daemon builds on Procursus SDKs. See `btstack-rootless/README.rootless.md` for the build command.

## License

GPL-3.0-or-later. The pairing code includes work adapted from UxPlay and csrp. Binary packages bundle BTstack runtime files from the historical `ch.ringwald.btstack` jailbreak package by Matthias Ringwald.
