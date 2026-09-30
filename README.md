# Float Dash

Live telemetry from a Refloat board on a Garmin watch, straight over Bluetooth — no phone in the
loop. Connect the watch to any VESC node on the board (the controller, a Bluetooth bridge or a VESC
BMS); it finds the controller and the BMS on the CAN bus by itself.

That also means the watch and a phone app can ride side by side: pair the phone with the board's
Bluetooth bridge and the watch with the BMS, and each has its own connection to the same CAN bus.

## Two apps

- **Float Dash** (watch app, `watch/`): five data pages, switched with UP/DOWN.
  - Main: battery, speed, duty, controller/motor temperature
  - Speed: speed as large as possible, duty as a bar
  - Battery: state of charge, pack voltage and current, lowest and highest cell
  - Power: battery and motor current, temperatures
  - Ride: Refloat state, pitch, roll, footpads, trip distance

  The first time, START opens the board picker; afterwards it reconnects on its own and START opens
  the menu:
  - **Tunes**: four named slots. *Save* stores the board's Refloat config; *Apply* writes a stored
    one back after a confirmation. See below.
  - **Lights** and **Headlight** switches. Refloat 1.2+ keeps these as a runtime override until the
    board powers off; older Refloat writes them to the config.
  - **Remote tilt**: UP and DOWN change the held input in ~10 % steps, START returns it to 0. The
    tilt stays while the app runs, shows at the top of every page, and ends when the app closes or
    the link drops. It needs *Remote tilt type* = UART in the board's tune.
  - **Switch board** picks a different board.
- **Float Dash Field** (data field, `field/`): speed, duty and battery inside a native Garmin
  activity. Use it with a course, so navigation stays Garmin's own: put the field in half of a
  two-field data screen next to native navigation fields. It pairs by itself with the device named
  in its settings, or the first device advertising the VESC Bluetooth service.

Both read the watch's distance setting for km/h or mph.

A VESC Bluetooth module takes one connection at a time, so the two apps hand the board over: each
holds it only while it runs and lets go when it closes. Each remembers the board it used last and
connects to it by name on start; while the other app still holds it, the screen says
**WAITING FOR BOARD** and connects as soon as it is free. Leave the activity before opening the
watch app on the same board.

## Tunes

A stored tune is a snapshot of the board's whole Refloat config, written back byte for byte. That
means it can only return the board to a state it has been in — but also that it restores the
snapshot's light and battery settings along with the ride feel. (Editing single tune fields would
need the config schema, which the board only sends compressed; a watch cannot unpack it.)

Applying refuses when:
- the board is engaged, rolling or a footpad is pressed (checked before reading and again before
  writing),
- the snapshot's config signature differs from the board's — i.e. it was saved on another Refloat
  version,
- there is no live data.

Every write is read back and compared. Other apps connected to the same board (e.g. Vescape on the
phone) still hold the config they read before, so let them re-read it after applying a tune.

## How it talks to the board

VESC packets over the Nordic UART Service. The connected node is asked for Refloat's
`GET_ALLDATA` first; if it is not the controller, the watch pings the CAN bus and asks each node
through `COMM_FORWARD_CAN` until one answers. The CAN id a BMS reports as its controller is tried
first. The BMS is found the same way with `COMM_BMS_GET_VALUES`. Where the controller was found is
remembered; set "Controller CAN ID" in the app settings to skip the search.

## Build

Needs the [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) and a developer key
(`~/.garmin/developer_key.der` by default).

```bash
make build   # build/float-dash.prg and build/float-dash-field.prg
make test    # unit tests; start the Connect IQ simulator first
```

Sideload by copying the `.prg` files to `GARMIN/APPS` on the watch (on macOS through OpenMTP).
Targets the Fenix 7 Pro for now; other watches need their product id in the manifests.

## Credits

The VESC framing, Refloat `ALLDATA` and BMS decoding follow [Vescape](https://github.com/vescape-app/vescape)
(GPL-3.0-or-later) and are tested against its vectors. The BMS layout was checked against
[`vesc_bms_fw`](https://github.com/vedderb/vesc_bms_fw) and the Refloat layout against
[`lukash/refloat`](https://github.com/lukash/refloat). [WheelDash](https://github.com/blkfribourg/WheelDash)
showed that a standalone Garmin VESC app is possible.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
