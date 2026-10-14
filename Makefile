# Build the Bloom Syncthing app.
#
#   make build     download the syncthing binary and CA bundle into the app
#   make release   assemble dist/Syncthing.app.zip
#   make push      adb push the app onto a connected device
#   make clean     remove downloads and dist/

APP_NAME := Syncthing
APP_DIR := $(APP_NAME).app
ARCH := arm64

SYNCTHING_VERSION ?= v2.1.3
SYNCTHING_TARBALL := syncthing-linux-$(ARCH)-$(SYNCTHING_VERSION).tar.gz
SYNCTHING_URL := https://github.com/syncthing/syncthing/releases/download/$(SYNCTHING_VERSION)/$(SYNCTHING_TARBALL)
SYNCTHING_LICENSE_URL := https://raw.githubusercontent.com/syncthing/syncthing/$(SYNCTHING_VERSION)/LICENSE
CHECKSUM_FILE := checksums/syncthing-$(SYNCTHING_VERSION).sha256

CACERT_URL := https://curl.se/ca/cacert.pem

# Where `make push` puts it. Bloom moved apps out of Tools/<platform>/ and
# into one shared _system/apps/ when it renamed the extension.
PUSH_APPS_DIR ?= _system/apps
PUSH_SDCARD_PATH ?= /mnt/SDCARD

.PHONY: all build release push clean lint test check

all: release

build: $(APP_DIR)/bin/$(ARCH)/syncthing $(APP_DIR)/certs/ca-certificates.crt

# The tarball is verified against a checksum committed in this repo, so a
# tampered or truncated download fails the build rather than shipping.
$(APP_DIR)/bin/$(ARCH)/syncthing:
	mkdir -p $(APP_DIR)/bin/$(ARCH)
	curl -sSLf -o /tmp/$(SYNCTHING_TARBALL) "$(SYNCTHING_URL)"
	cd /tmp && shasum -a 256 -c $(CURDIR)/$(CHECKSUM_FILE) || \
		sha256sum -c $(CURDIR)/$(CHECKSUM_FILE)
	tar -xzf /tmp/$(SYNCTHING_TARBALL) -C /tmp \
		syncthing-linux-$(ARCH)-$(SYNCTHING_VERSION)/syncthing
	mv /tmp/syncthing-linux-$(ARCH)-$(SYNCTHING_VERSION)/syncthing $@
	chmod +x $@
	curl -sSLf -o $(APP_DIR)/bin/$(ARCH)/syncthing.LICENSE "$(SYNCTHING_LICENSE_URL)"
	rm -rf /tmp/syncthing-linux-$(ARCH)-$(SYNCTHING_VERSION) /tmp/$(SYNCTHING_TARBALL)

# These firmwares have no system trust store, so the app carries its own.
$(APP_DIR)/certs/ca-certificates.crt:
	mkdir -p $(APP_DIR)/certs
	curl -sSLf -o $@ "$(CACERT_URL)"

release: build
	rm -rf dist
	mkdir -p dist
	cp -R $(APP_DIR) dist/$(APP_DIR)
	find dist/$(APP_DIR) -name '.DS_Store' -delete
	chmod +x dist/$(APP_DIR)/app.sh
	chmod +x dist/$(APP_DIR)/bin/service-on dist/$(APP_DIR)/bin/service-off \
		dist/$(APP_DIR)/bin/sync-now dist/$(APP_DIR)/bin/wifi-watch
	chmod +x dist/$(APP_DIR)/bin/$(ARCH)/syncthing
	cd dist && zip -qr $(APP_NAME).app.zip $(APP_DIR)
	ls -lh dist

# POSIX sh only — Bloom runs BusyBox ash, so bashisms are a runtime failure.
lint:
	cd $(APP_DIR) && shellcheck -s sh -x app.sh \
		bin/service-on bin/service-off bin/sync-now bin/wifi-watch

# The app can't run on a build machine, so the tests stub Bloom's verbs and
# the system calls we make, then drive the real app.sh and bin/ scripts.
test:
	./test/run.sh

check: lint test

push: release
	adb push "dist/$(APP_DIR)/." "$(PUSH_SDCARD_PATH)/$(PUSH_APPS_DIR)/$(APP_DIR)"

clean:
	rm -rf dist $(APP_DIR)/bin/$(ARCH) $(APP_DIR)/certs
