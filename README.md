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

  START opens the board picker; "Forget board" pairs with a different one.
- **Float Dash Field** (data field, `field/`): speed, duty and battery inside a native Garmin
  activity. Use it with a course, so navigation stays Garmin's own: put the field in half of a
  two-field data screen next to native navigation fields. It pairs by itself with the device named
  in its settings, or the first device advertising the VESC Bluetooth service.

Both read the watch's distance setting for km/h or mph.

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
