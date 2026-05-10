# Packaging

Build the app on the iPad, test it, then package the installed bundle.

```sh
./scripts/fetch-installed-app.sh
./scripts/build-rootful-deb.sh
./scripts/generate-apt-repo.py repo
```

The package installs `/Applications/Showcase.app` and bundles the BTstack runtime files required by the receiver.

```text
/usr/bin/BTdaemon
/usr/lib/libBTstack.dylib
/Library/LaunchDaemons/ch.ringwald.BTstack.plist
```

APT metadata declares `firmware (>= 12.0)`, `libssl3 (>= 3.2.1)`, and `uikittools`.

Do not commit `payload/`, `build/`, or `repo/` to the source branch. Publish the generated `repo/` directory to the web path that serves `https://aminerostane.com/repo`.
