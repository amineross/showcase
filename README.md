# Showcase — Rootless Repack (Dopamine / iOS 15–17)

Unofficial rootless repack of [Amine Rostane's **Showcase**](https://github.com/amineross/showcase) — a software-only wireless CarPlay receiver for jailbroken iPads.

The first public beta ships in two package architectures. Rootful users get the iOS 12-14 build. Rootless users get the iOS 15-17 build for Dopamine and palera1n rootless.

All credit for the original research, reverse engineering, and code goes to **Amine Rostane** ([hello@aminerostane.com](mailto:hello@aminerostane.com)). This repo only provides a repackaged `.deb` compatible with rootless jailbreaks.

---

## What is Showcase?

Showcase lets a jailbroken iPad act as a wireless CarPlay receiver **without any external MFi dongle or hardware coprocessor**. It works by reusing the iPad's own Apple BAA (Basic Attestation Authority) credentials to satisfy the CarPlay authentication handshake.

Full technical write-up by the original author: [mfi-carplay-baa-bypass.pdf](https://aminerostane.com/showcase/report/mfi-carplay-baa-bypass.pdf)

---

## Why this repack?

The original `.deb` (`iphoneos-arm`) targets **rootful** jailbreaks (paths under `/usr/`, `/Library/`, `/Applications/`).

This repack fixes three things so it works on **rootless** jailbreaks (Dopamine, palera1n rootless):

| What was changed | Original | Fixed |
|---|---|---|
| All install paths | `/usr/`, `/Applications/`, `/Library/` | `/var/jb/usr/`, `/var/jb/Applications/`, `/var/jb/Library/` |
| `carplay_services` dylib link | `/usr/lib/libcrypto.3.dylib` | `/var/jb/usr/lib/libcrypto.3.dylib` |
| `carplay_bt` dylib link | `/usr/lib/libBTstack.dylib` | `/var/jb/usr/lib/libBTstack.dylib` |
| `libBTstack.dylib` install name | `/usr/lib/libBTstack.dylib` | `/var/jb/usr/lib/libBTstack.dylib` |
| Launch daemon path | `/usr/bin/BTdaemon` | `/var/jb/usr/bin/BTdaemon` |
| Package architecture | `iphoneos-arm` | `iphoneos-arm64` |
| `libssl3` version requirement | `>= 3.2.1` | `>= 3.0.0` |

---

## Requirements

| Item | Requirement |
| --- | --- |
| iPad | Cellular iPad with Personal Hotspot |
| Tested rootful receiver | iPad Air 1 cellular, A1475, iPad4,2, iOS 12.5.8, checkra1n |
| Community rootless target | Cellular iPads on iOS 15-17, Dopamine or palera1n rootless |
| Runtime packages | `libssl3`, `uikittools` |

Sileo, Cydia, and Zebra install runtime packages through normal APT dependency resolution. Manual dependency installation is only needed when sideloading a `.deb` with `dpkg -i`.

The package bundles `BTdaemon`, `libBTstack.dylib`, and the BTstack launch daemon needed for `/tmp/BTstack`. It conflicts with the old `ch.ringwald.btstack` package to avoid file ownership collisions.

> **Rootless sideloading extra:** also install `libssl3 >= 3.0.0` and `uikittools` from [Procursus](https://apt.procurs.us/) before running `dpkg -i`.
>
> Tested on: iPad 7th gen, iOS 17.0, Dopamine (rootless)

---

## Installation

### Via APT (Sileo / Cydia / Zebra)

Add the package source:

```text
https://aminerostane.com/repo
```

Then install `Showcase`. Runtime dependencies (`libssl3`, `uikittools`) are pulled in automatically.

### Sideloading the rootless `.deb` manually

For users who prefer to install the `iphoneos-arm64.deb` directly without adding an APT source:

**1. Install dependencies first**

In **Sileo** or **Zebra**, add the Procursus source:
```
https://apt.procurs.us/
```
Then install: `libssl3` and `uikittools`.

**2. Transfer the `.deb` to your iPad**

Via AirDrop, or via SSH:
```bash
scp com.rostane.showcase_1.0.beta1-1_iphoneos-arm64.deb root@<iPad-IP>:/var/mobile/
```

**3. Install via SSH / NewTerm**

```bash
dpkg -i /var/mobile/com.rostane.showcase_1.0.beta1-1_iphoneos-arm64.deb
```

**4. Re-sign the patched binaries**

The dylib path patches invalidate the original code signature. Re-sign with `ldid`:

```bash
ldid -S /var/jb/Applications/Showcase.app/carplay_services
ldid -S /var/jb/Applications/Showcase.app/carplay_bt
ldid -S /var/jb/usr/lib/libBTstack.dylib
```

**5. Load the Bluetooth daemon**

```bash
launchctl load /var/jb/Library/LaunchDaemons/ch.ringwald.BTstack.plist
```

**6. Open Showcase and follow the pairing flow**

- Enable Personal Hotspot on the iPad
- Open the Showcase app
- On your iPhone: Settings → General → CarPlay → Add Car → select your iPad

### Building from source

Build and test the app on the iPad first.

```sh
cd packaging
./scripts/fetch-installed-app.sh
./scripts/build-rootful-deb.sh
./scripts/build-rootless-deb.sh
./scripts/generate-apt-repo.py repo
```

The `.deb` files land in `packaging/build/`. The APT repository lands in `packaging/repo/`.

For GitHub Releases, upload both `.deb` files from `packaging/build/` after you rebuild the packages. The rootful asset ends in `iphoneos-arm.deb`; the rootless asset ends in `iphoneos-arm64.deb`.

For Sileo, Cydia, and Zebra, publish the generated `packaging/repo/` contents to the web path that serves `https://aminerostane.com/repo`.

---

## How it works (summary)

```
iPhone ──Bluetooth/iAP2──► iPad (Showcase)
                                │
                    BAA cert + ECDSA sign
                                │
         ◄──── join iPad Hotspot ────
                                │
         ──── AirPlay RTSP TCP 7000 ──►
                                │
                    BAA-backed MFi-SAP auth
                                │
         ◄──── H.264 screen stream ────
         ──── HID touch reports ───────►
```

The iPad reuses its own Apple-issued device identity (BAA certificate chain) to satisfy both the iAP2 Bluetooth authentication and the AirPlay MFi-SAP auth-setup. No external MFi coprocessor needed.

---

## Logs

```text
/var/mobile/Library/Showcase/logs/app.log
/var/mobile/Library/Showcase/logs/btdaemon.log
/var/mobile/Library/Showcase/logs/carplay_bt.log
/var/mobile/Library/Showcase/logs/carplay_services.log
```

---

## Troubleshooting

**`dpkg` rejects the package**
Make sure you installed `libssl3` and `uikittools` from the Procursus rootless repo first.

**CarPlay doesn't appear on iPhone**
- Confirm Personal Hotspot is active on the iPad
- Run `launchctl list | grep BTstack` to verify the daemon is running
- Check `/var/log/BTstack.log` for errors

**App crashes on launch**
Re-run the `ldid -S` commands from step 4 — the patched binaries must be re-signed after install.

---

## Credits

- **Amine Rostane** — original Showcase app, BAA bypass research
- **TorranceTech** — rootless repack (dylib path patches, iphoneos-arm64 repackaging, iOS 17 / Dopamine compatibility)

## BTstack Rootless Source

The rootless package bundles a patched BTstack daemon. Its source lives in `btstack-rootless/`.

The patch set fixes classic BR/EDR authentication state, incoming RFCOMM cid registration, RFCOMM data routing, and classic-only daemon builds on Procursus SDKs. See `btstack-rootless/README.rootless.md` for the build command.

## License

This repo redistributes a modified binary. All original intellectual property belongs to Amine Rostane. Use at your own risk.
