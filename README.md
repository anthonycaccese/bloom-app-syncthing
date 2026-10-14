# Syncthing for Bloom

[Syncthing](https://syncthing.net) bundled as a native [Bloom](https://github.com/) app

When installed and enabled, Syncthing runs as a background process (only when wifi is connected).  The app also provides a quick view of the IP address to use for accessing Syncthing's Web GUI, the device's unique generated id, and a way to view recent changes.

All other Syncthing configuration (folder set up, gui settings, etc) is done via Syncthing'a Web GUI.

## Preview
![Syncthing for Bloom configuration](https://github.com/user-attachments/assets/80defa82-c318-47a2-8c51-4b31dba01286)

## Usage

### Install:

1. Download `Syncthing.app.zip` from the [latest release](../../releases/latest)
2. Unzip it
3. Copy `Syncthing.app` to your SD card at:

    ```
    /mnt/SDCARD/_system/apps/
    ```

### First time setup:

1. Open Syncthing via Menu > Apps
2. Set `Enabled` to `On` (this will start the Syncthing service, set it to start when Bloom does, generate Syncthing's initial configuration, create a unique Device ID and enable the Web GUI)
3. Open the Web GUI (the IP next to `Web GUI` in the UI) on another device to configure your folders and a web gui user/password.

Notes
- When Syncthing is enabled it will run in the background when Wi-Fi is enabled and connected.
- Setting `Enabled` to `Off` will retain all of your settings so you can also manually manage if syncthing is on or off through that setting.
- If you ever need to reset your Syncthing configuration you can use the `Reset Configuration` option.  Note: choosing this will delete your syncthing settings, shares and reset your device ID.  It will not touch your actual files, just Syncthing's references to them.

### Update:

1. Open Syncthing via Menu > Apps
2. Set `Enabled` to `Off` then exit the App
3. Copy the latest version of `Syncthing.app` to your SD card at:
    ```
    /mnt/SDCARD/_system/apps/
    ```
4. Open Syncthing via Menu > Apps
5. Set `Enabled` to `On`

Notes
- Syncthing's config lives outside the app under Bloom's configuration path (`$CONFIG_PATH`), so replacing the app with a newer build will keep your configuration and device ID.

### Uninstall:

1. Open Syncthing via Menu > Apps
2. Set `Enabled` to `Off` (this will remove Syncthing from Bloom's start up and turn off the service)
3. Delete the `Syncthing.app` from: `/mnt/SDCARD/_system/apps/`
4. Delete the `Syncthing` folder from: `/mnt/SDCARD/config/`

## Development Notes

### App Layout:

    Syncthing.app/
      app.sh              
      desc.txt            a one-line description for the Apps list
      icon.png            an icon to display in Bloom's menu UI
      bin/
        common.sh         shared paths and helpers
        service-on        generates config on first run, starts the daemon
        service-off       stops the daemon
        sync-now          POST /rest/db/scan, rescans every folder for changes when run
        wifi-watch        gates syncthing running based on wifi being on or off
        arm64/syncthing   pinned syncthing binary downloaded at build time
      certs/              CA bundle, downloaded at build time

### Building:

    make build     download the syncthing binary and CA bundle into the app
    make test      run the off-device test suite
    make lint      shellcheck, in POSIX sh mode
    make check     lint + test
    make release   assemble dist/Syncthing.app.zip
    make push      adb push the app onto a connected device
    make clean     remove downloads and dist/

The syncthing binary is downloaded from the official GitHub release and verified against a checksum committed in `checksums/`. To bump it, set `SYNCTHING_VERSION` and add the matching checksum file.

### Testing:

Bloom's verbs only exist when actually running Bloom on a device so `test/stubs/` stands in for Bloom's native verbs (`form`, `message`, `confirm`, `notify`, `progress`, `popup`). 

For the system state the tests read (`pgrep`, `killall`, `ip`, `/sys/class/net`) and drive the real `app.sh` and `bin/` scripts against those covering the form flow, the `post.sh` toggle and the Wi-Fi watcher's start/stop behaviour.

`flags.test.sh` downloads the build of the pinned syncthing version set in `checksums` and checks that each flag `bin/service-on` passes actually exists in it. Set `SKIP_NETWORK_TESTS=1` to skip it offline.

## Credits & Acknowledgments

- This is hobby project for me so I've used using Claude Code to help build this app and interact with Syncthing's binary. I've reviewed the code and tested it extensively for each of Bloom's use cases (wifi on/off, sleep, start up, etc...) and common syncthing configurations.  That said, if you have concerns with that, I am glad to talk through the structure of the app in more detail. Also, please feel free to fork this repo, update any aspects and tailor things to your own use case; that's why the source is fully open and available.

## License

The app's own code (`app.sh`, the scripts in `bin/`, the tests and the build files) is licensed under the [GNU General Public License v3.0](LICENSE).

The release bundles third-party software that keeps its own license:

- **Syncthing** — the unmodified `syncthing` binary in `bin/arm64/` is © The Syncthing Authors and licensed under the [Mozilla Public License 2.0](https://github.com/syncthing/syncthing/blob/main/LICENSE). Its license ships next to it as `bin/arm64/syncthing.LICENSE`, and its source code is available at [github.com/syncthing/syncthing](https://github.com/syncthing/syncthing) under the release tag matching the pinned version (see `SYNCTHING_VERSION` in the `Makefile`).
- **CA certificates** — `certs/ca-certificates.crt` is Mozilla's CA certificate bundle as [distributed by the curl project](https://curl.se/docs/caextract.html), licensed under the [Mozilla Public License 2.0](https://www.mozilla.org/MPL/2.0/).
