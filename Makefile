# Build and test with the Connect IQ SDK the SDK Manager marks current.
# Override with CONNECTIQ_SDK=/path/to/sdk, DEVICE=<product id>, DEVELOPER_KEY=/path/to/key.der.
CONNECTIQ_SDK ?= $(shell cat "$(HOME)/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg" 2>/dev/null)
DEVICE ?= fenix7pro
# Connect IQ requires the same key for every Store update of an app, so it lives outside the repo.
DEVELOPER_KEY ?= $(HOME)/.garmin/developer_key.der

MONKEYC = "$(CONNECTIQ_SDK)/bin/monkeyc" -d $(DEVICE) -y "$(DEVELOPER_KEY)" -w -l 3
MONKEYDO = "$(CONNECTIQ_SDK)/bin/monkeydo"

.PHONY: build watch field test clean

build: watch field
	@echo "Sideload: copy build/float-dash.prg and build/float-dash-field.prg to GARMIN/APPS on the watch."

watch:
	@mkdir -p build
	$(MONKEYC) -f watch/monkey.jungle -o build/float-dash.prg

field:
	@mkdir -p build
	$(MONKEYC) -f field/monkey.jungle -o build/float-dash-field.prg

# Needs the Connect IQ simulator running (open it from the SDK's bin/ConnectIQ.app).
test:
	@mkdir -p build
	$(MONKEYC) -f watch/monkey.jungle --unit-test -o build/float-dash-test.prg
	$(MONKEYDO) build/float-dash-test.prg $(DEVICE) -t

clean:
	rm -rf build
