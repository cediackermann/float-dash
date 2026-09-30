import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

const TUNE_SLOTS = 4;
const STORAGE_TUNES = "tunes";

//! A saved tune: the board's whole Refloat config (package signature + encoded config), as read.
class Tune {
    var name as String;
    var snapshot as ByteArray;
    //! "1.2" style, for the list; compatibility itself is decided by the snapshot's signature.
    var version as String;

    function initialize(name as String, snapshot as ByteArray, version as String) {
        self.name = name;
        self.snapshot = snapshot;
        self.version = version;
    }
}

enum TuneStep {
    STEP_IDLE,
    STEP_SAVE_READ,
    STEP_APPLY_READ,
    STEP_APPLY_WRITE,
    STEP_APPLY_VERIFY
}

//! What the rider can change on the board from the watch app: the two light switches and up to four
//! stored tunes.
//!
//! A tune is a snapshot of the whole Refloat config. Changing single tune fields would need the
//! config schema, which the board only hands out compressed and a watch cannot unpack; a snapshot is
//! written back byte for byte, so it can only ever put the board in a state it has been in. It also
//! restores everything else in the Refloat config as it was (lights, battery settings), which is
//! why applying one says so. Guards: never while the board is engaged or rolling, never across a
//! different config signature (another Refloat version), and every write is read back.
class BoardControls {
    //! LIGHT_* bits the board last reported on, or null before it has said.
    var lights as Number? = null;
    //! What the last tune action is doing or how it ended, for the status screen.
    var tuneStatus as String? = null;

    private var _board as Board;
    private var _tunes as Array<Tune?>;
    private var _step as TuneStep = STEP_IDLE;
    private var _slot as Number = 0;
    private var _pendingName as String = "";

    function initialize(board as Board) {
        _board = board;
        _tunes = loadTunes();
        board.controls = self;
    }

    function tune(slot as Number) as Tune? {
        return _tunes[slot];
    }

    function isBusy() as Boolean {
        return _step != STEP_IDLE;
    }

    function setLight(light as Number, on as Boolean) as Void {
        _board.session.request(ONE_OFF_LIGHTS, Vesc.lights(light, on, _board.legacyLights()));
        _board.pump();
    }

    //! Reads the board's current config into `slot` under `name`.
    function saveTune(slot as Number, name as String) as Void {
        if (!start("Reading board config…")) {
            return;
        }
        _slot = slot;
        _pendingName = name;
        _step = STEP_SAVE_READ;
        requestConfig();
    }

    //! Reads the board's config first, then writes the stored one if it is safe and different.
    function applyTune(slot as Number) as Void {
        var stored = _tunes[slot];
        if (stored == null || !start("Checking board…")) {
            return;
        }
        var refusal = unsafeToWrite();
        if (refusal != null) {
            finish(refusal);
            return;
        }
        _slot = slot;
        _step = STEP_APPLY_READ;
        requestConfig();
    }

    function rename(slot as Number, name as String) as Void {
        var stored = _tunes[slot];
        if (stored != null) {
            stored.name = name;
            storeTunes();
        }
    }

    function delete(slot as Number) as Void {
        _tunes[slot] = null;
        storeTunes();
    }

    function onOneOffReply(kind as OneOffKind, payload as ByteArray?) as Void {
        if (kind == ONE_OFF_LIGHTS) {
            if (payload != null) {
                lights = Decoders.lightsEcho(payload);
            }
            WatchUi.requestUpdate();
            return;
        }
        if (_step == STEP_IDLE) {
            return;
        }
        if (payload == null) {
            var mayHaveWritten = _step == STEP_APPLY_WRITE || _step == STEP_APPLY_VERIFY;
            finish(mayHaveWritten
                ? "No answer while writing. Check the board's tune in VESC Tool before riding."
                : "No answer from the board. Nothing was changed.");
            return;
        }
        if (kind == ONE_OFF_GET_CONFIG) {
            onConfig(Decoders.configSnapshot(payload) as ByteArray);
        } else if (kind == ONE_OFF_SET_CONFIG && _step == STEP_APPLY_WRITE) {
            tuneStatus = "Verifying…";
            _step = STEP_APPLY_VERIFY;
            requestConfig();
        }
        WatchUi.requestUpdate();
    }

    private function onConfig(current as ByteArray) as Void {
        if (_step == STEP_SAVE_READ) {
            _tunes[_slot] = new Tune(_pendingName, current, versionText());
            storeTunes();
            finish("Saved \"" + _pendingName + "\".");
            return;
        }
        var stored = _tunes[_slot] as Tune;
        if (_step == STEP_APPLY_VERIFY) {
            finish(current.equals(stored.snapshot)
                ? "Applied \"" + stored.name + "\"."
                : "The board did not keep \"" + stored.name + "\". Its config is unchanged or partly changed; check it in VESC Tool.");
            return;
        }
        // STEP_APPLY_READ: the signature is the config layout; another one means another Refloat.
        if (!current.slice(0, 4).equals(stored.snapshot.slice(0, 4))) {
            finish("\"" + stored.name + "\" was saved on a different Refloat version (" + stored.version + "). Not applied.");
            return;
        }
        if (current.equals(stored.snapshot)) {
            finish("\"" + stored.name + "\" is already on the board.");
            return;
        }
        // Checked again right before writing: the rider may have stepped on while we read.
        var refusal = unsafeToWrite();
        if (refusal != null) {
            finish(refusal);
            return;
        }
        tuneStatus = "Writing \"" + stored.name + "\"…";
        _step = STEP_APPLY_WRITE;
        _board.session.request(ONE_OFF_SET_CONFIG, Vesc.setConfig(stored.snapshot));
        _board.pump();
    }

    //! A reason not to write the config now, or null when it is safe.
    private function unsafeToWrite() as String? {
        var sample = _board.session.refloat;
        if (sample == null || _board.session.isStale(System.getTimer())) {
            return "No live data from the board. Not applied.";
        }
        if (sample.isEngaged() || sample.footpads() != 0 || sample.speed.abs() > 1.0) {
            return "Step off and stop the board first. Not applied.";
        }
        return null;
    }

    private function start(status as String) as Boolean {
        if (_step != STEP_IDLE) {
            return false;
        }
        if (_board.session.phase != PHASE_POLLING) {
            tuneStatus = "Board not connected.";
            return false;
        }
        tuneStatus = status;
        return true;
    }

    private function requestConfig() as Void {
        _board.session.request(ONE_OFF_GET_CONFIG, Vesc.getConfig());
        _board.pump();
    }

    private function finish(status as String) as Void {
        tuneStatus = status;
        _step = STEP_IDLE;
        WatchUi.requestUpdate();
    }

    private function versionText() as String {
        var version = _board.refloatVersion;
        return version == null ? "?" : version[0] + "." + version[1];
    }

    private function loadTunes() as Array<Tune?> {
        var tunes = new [TUNE_SLOTS] as Array<Tune?>;
        var stored = Storage.getValue(STORAGE_TUNES) as Array<Array?>?;
        if (stored != null) {
            for (var i = 0; i < TUNE_SLOTS && i < stored.size(); i++) {
                var entry = stored[i];
                if (entry != null && entry.size() == 3) {
                    tunes[i] = new Tune(entry[0] as String, entry[1] as ByteArray, entry[2] as String);
                }
            }
        }
        return tunes;
    }

    private function storeTunes() as Void {
        var stored = [] as Array<Storage.ValueType>;
        for (var i = 0; i < TUNE_SLOTS; i++) {
            var tune = _tunes[i];
            stored.add(tune == null ? null : [tune.name, tune.snapshot, tune.version] as Array<Storage.ValueType>);
        }
        Storage.setValue(STORAGE_TUNES, stored);
    }
}
