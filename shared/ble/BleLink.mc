import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.WatchUi;

//! Nordic UART Service, which VESC's Bluetooth modules expose: write requests to RX, replies arrive
//! as notifications on TX.
module Nus {
    const SERVICE = BluetoothLowEnergy.longToUuid(0x6E400001B5A3F393L, 0xE0A9E50E24DCCA9EL);
    const RX = BluetoothLowEnergy.longToUuid(0x6E400002B5A3F393L, 0xE0A9E50E24DCCA9EL);
    const TX = BluetoothLowEnergy.longToUuid(0x6E400003B5A3F393L, 0xE0A9E50E24DCCA9EL);
}

enum LinkState {
    LINK_REGISTERING,
    LINK_SCANNING,
    LINK_CONNECTING,
    LINK_READY
}

//! What the link hands upwards: link up/down, write capacity freed, and complete, CRC-checked VESC
//! payloads.
typedef LinkListener as interface {
    function onLinkUp() as Void;
    function onLinkDown() as Void;
    function onLinkWritable() as Void;
    function onLinkPacket(payload as ByteArray) as Void;
};

//! Bluetooth to one VESC node over NUS (controller, Bluetooth bridge or BMS alike). Scans for the service, pairs with the chosen device (or
//! reconnects to the one paired before), turns on TX notifications, and sends one write at a time:
//! Connect IQ rejects a request while another is outstanding.
class BleLink extends BluetoothLowEnergy.BleDelegate {
    var state as LinkState = LINK_REGISTERING;
    //! Devices seen while scanning, for the picker. Newest name wins for a given device.
    var found as Array<BluetoothLowEnergy.ScanResult> = [] as Array<BluetoothLowEnergy.ScanResult>;

    private var _listener as LinkListener;
    private var _autoPair as Boolean;
    private var _preferredName as String?;
    private var _device as BluetoothLowEnergy.Device? = null;
    private var _rx as BluetoothLowEnergy.Characteristic? = null;
    private var _writing as Boolean = false;
    private var _reassembler as Reassembler = new Reassembler();

    function initialize(listener as LinkListener, autoPair as Boolean, preferredName as String?) {
        BleDelegate.initialize();
        _listener = listener;
        _autoPair = autoPair;
        _preferredName = (preferredName != null && !preferredName.equals("")) ? preferredName : null;
    }

    function start() as Void {
        BluetoothLowEnergy.setDelegate(self);
        try {
            BluetoothLowEnergy.registerProfile({
                :uuid => Nus.SERVICE,
                :characteristics => [
                    { :uuid => Nus.RX },
                    { :uuid => Nus.TX, :descriptors => [BluetoothLowEnergy.cccdUuid()] },
                ],
            });
        } catch (e instanceof BluetoothLowEnergy.ProfileRegistrationException) {
            // Registrations can outlive an app run (the simulator keeps them); NUS is already there.
            onProfileRegister(Nus.SERVICE, BluetoothLowEnergy.STATUS_SUCCESS);
        }
    }

    function stop() as Void {
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
    }

    //! Pair with a device the rider picked. The watch keeps the pairing and reconnects on its own.
    function pair(result as BluetoothLowEnergy.ScanResult) as Void {
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
        forget();
        _device = BluetoothLowEnergy.pairDevice(result);
        state = LINK_CONNECTING;
    }

    //! Drop the pairing so a different board can be picked.
    function forget() as Void {
        var paired = BluetoothLowEnergy.getPairedDevices();
        for (var device = paired.next(); device != null; device = paired.next()) {
            BluetoothLowEnergy.unpairDevice(device as BluetoothLowEnergy.Device);
        }
        _device = null;
        _rx = null;
    }

    function rescan() as Void {
        forget();
        found = [] as Array<BluetoothLowEnergy.ScanResult>;
        state = LINK_SCANNING;
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
    }

    function canSend() as Boolean {
        return state == LINK_READY && !_writing && _rx != null;
    }

    //! Frames and writes a request. Callers check `canSend` first.
    function send(payload as ByteArray) as Void {
        if (!canSend()) {
            return;
        }
        _writing = true;
        (_rx as BluetoothLowEnergy.Characteristic).requestWrite(Vesc.frame(payload), {
            :writeType => BluetoothLowEnergy.WRITE_TYPE_WITH_RESPONSE,
        });
    }

    function onProfileRegister(uuid as BluetoothLowEnergy.Uuid, status as BluetoothLowEnergy.Status) as Void {
        var paired = BluetoothLowEnergy.getPairedDevices().next();
        if (paired != null) {
            // Paired in an earlier run: the system reconnects it, onConnectedStateChanged follows.
            _device = paired as BluetoothLowEnergy.Device;
            state = LINK_CONNECTING;
            if (_device.isConnected()) {
                onConnectedStateChanged(_device, BluetoothLowEnergy.CONNECTION_STATE_CONNECTED);
            }
        } else {
            rescan();
        }
        WatchUi.requestUpdate();
    }

    function onScanResults(scanResults as BluetoothLowEnergy.Iterator) as Void {
        for (var result = scanResults.next(); result != null; result = scanResults.next()) {
            var scan = result as BluetoothLowEnergy.ScanResult;
            // Some modules put NUS in the scan response instead of the advertisement, so named
            // devices are listed too; the picker marks the ones that advertise it.
            if (!advertisesNus(scan) && scan.getDeviceName() == null) {
                continue;
            }
            var known = false;
            for (var i = 0; i < found.size(); i++) {
                if (found[i].isSameDevice(scan)) {
                    found[i] = scan;
                    known = true;
                }
            }
            if (!known) {
                found.add(scan);
            }
            if (_autoPair && state == LINK_SCANNING && matchesPreferred(scan)) {
                pair(scan);
                break;
            }
        }
        WatchUi.requestUpdate();
    }

    //! The named device when a name is set, otherwise any device advertising NUS.
    private function matchesPreferred(scan as BluetoothLowEnergy.ScanResult) as Boolean {
        if (_preferredName == null) {
            return advertisesNus(scan);
        }
        var name = scan.getDeviceName();
        return name != null && name.equals(_preferredName);
    }

    function onConnectedStateChanged(device as BluetoothLowEnergy.Device, connectionState as BluetoothLowEnergy.ConnectionState) as Void {
        if (_device == null || device != _device) {
            return;
        }
        if (connectionState != BluetoothLowEnergy.CONNECTION_STATE_CONNECTED) {
            var wasReady = state == LINK_READY;
            state = LINK_CONNECTING;
            _rx = null;
            _writing = false;
            if (wasReady) {
                _listener.onLinkDown();
            }
            WatchUi.requestUpdate();
            return;
        }
        var service = device.getService(Nus.SERVICE);
        var tx = service != null ? service.getCharacteristic(Nus.TX) : null;
        _rx = service != null ? service.getCharacteristic(Nus.RX) : null;
        var cccd = tx != null ? tx.getDescriptor(BluetoothLowEnergy.cccdUuid()) : null;
        if (cccd == null || _rx == null) {
            // Not a VESC NUS device after all.
            forget();
            rescan();
            return;
        }
        _reassembler.reset();
        cccd.requestWrite([0x01, 0x00]b);
    }

    function onDescriptorWrite(descriptor as BluetoothLowEnergy.Descriptor, status as BluetoothLowEnergy.Status) as Void {
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            return;
        }
        state = LINK_READY;
        _writing = false;
        _listener.onLinkUp();
        WatchUi.requestUpdate();
    }

    function onCharacteristicWrite(characteristic as BluetoothLowEnergy.Characteristic, status as BluetoothLowEnergy.Status) as Void {
        _writing = false;
        _listener.onLinkWritable();
    }

    function onCharacteristicChanged(characteristic as BluetoothLowEnergy.Characteristic, value as ByteArray) as Void {
        var packets = _reassembler.feed(value);
        for (var i = 0; i < packets.size(); i++) {
            _listener.onLinkPacket(packets[i]);
        }
    }

    function advertisesNus(scan as BluetoothLowEnergy.ScanResult) as Boolean {
        var uuids = scan.getServiceUuids();
        for (var uuid = uuids.next(); uuid != null; uuid = uuids.next()) {
            if (uuid.equals(Nus.SERVICE)) {
                return true;
            }
        }
        return false;
    }
}
