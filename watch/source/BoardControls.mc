import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

const TUNE_SLOTS = 4;
//! Key changed from the whole-config snapshots of the first version, which are not tunes.
const STORAGE_TUNES = "tunesV2";

//! A saved tune: the bytes of the tune fields (see TuneCodec) and the config signature they were
//! read under. A tune only goes back onto a board with the same signature: another layout means
//! another Refloat version, where the same bytes would land on other fields.
class Tune {
    var name as String;
    var signature as Number;
    var bytes as ByteArray;
    var version as String;

    function initialize(name as String, signature as Number, bytes as ByteArray, version as String) {
        self.name = name;
        self.signature = signature;
        self.bytes = bytes;
        self.version = version;
    }
}

enum TuneStep {
    STEP_IDLE,
    STEP_REFRESH_READ,
    STEP_SAVE_READ,
    STEP_APPLY_READ,
    STEP_APPLY_WRITE,
    STEP_APPLY_VERIFY
}

//! What the rider can change on the board from the watch app: the two light switches and up to four
//! stored tunes.
//!
//! A tune is how the board rides — Refloat's Tune, Tune Modifiers and ATR fields — and nothing else.
//! Saving reads the board's config and keeps those fields. Applying reads the board's config again,
//! replaces only those fields, writes it and reads it back: lights, battery, faults and remote stay
//! as they are on the board. Applying only happens while the board stands still: not engaged, feet
//! off, not rolling — checked before the read and again right before the write.
class BoardControls {
    //! LIGHT_* bits the board last reported on, or null before it has said.
    var lights as Number? = null;
    //! What the last tune action is doing or how it ended, for the status screen.
    var tuneStatus as String? = null;
    //! Tune fields on the board as last read, with their signature, for "on board" in the list.
    var boardTune as Tune? = null;

    private var _board as Board;
    private var _tunes as Array<Tune?>;
    private var _step as TuneStep = STEP_IDLE;
    private var _slot as Number = 0;
    private var _pendingName as String = "";
    private var _written as ByteArray? = null;

    function initialize(board as Board) {
        _board = board;
        _tunes = loadTunes();
        board.controls = self;
    }

    function tune(slot as Number) as Tune? {
        return _tunes[slot];
    }

    //! Whether a slot holds exactly what the board rides with now (as last read).
    function isOnBoard(slot as Number) as Boolean {
        var stored = _tunes[slot];
        var current = boardTune;
        return stored != null && current != null &&
            stored.signature == current.signature && stored.bytes.equals(current.bytes);
    }

    function isBusy() as Boolean {
        return _step != STEP_IDLE && _step != STEP_REFRESH_READ;
    }

    function setLight(light as Number, on as Boolean) as Void {
        _board.session.request(ONE_OFF_LIGHTS, Vesc.lights(light, on, _board.legacyLights()));
        _board.pump();
    }

    //! Reads the board's tune quietly, so the list can show which slot is on the board.
    function refreshBoardTune() as Void {
        if (_step == STEP_IDLE && _board.session.phase == PHASE_POLLING) {
            _step = STEP_REFRESH_READ;
            requestConfig();
        }
    }

    //! Pulls the board's current tune into `slot` under `name`.
    function saveTune(slot as Number, name as String) as Void {
        if (!start("Reading the board's tune…")) {
            return;
        }
        _slot = slot;
        _pendingName = name;
        _step = STEP_SAVE_READ;
        requestConfig();
    }

    function applyTune(slot as Number) as Void {
        if (_tunes[slot] == null || !start("Checking the board…")) {
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
            finish(_step == STEP_REFRESH_READ ? null : (mayHaveWritten
                ? "No answer while writing. Check the board's tune in VESC Tool before riding."
                : "No answer from the board. Nothing was changed."));
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

    private function onConfig(snapshot as ByteArray) as Void {
        var layout = TuneCodec.layoutOf(snapshot);
        if (layout == null) {
            // Unknown Refloat layout: no field is touched without knowing where it is.
            boardTune = null;
            finish(_step == STEP_REFRESH_READ ? null
                : "This Refloat version is not supported for tunes yet. Nothing was changed.");
            return;
        }
        var ranges = layout[1];
        var signature = TuneCodec.signature(snapshot);
        var onBoard = new Tune("", signature, TuneCodec.extract(snapshot, ranges), versionText());
        boardTune = onBoard;

        if (_step == STEP_REFRESH_READ) {
            finish(null);
            return;
        }
        if (_step == STEP_SAVE_READ) {
            _tunes[_slot] = new Tune(_pendingName, signature, onBoard.bytes, versionText());
            storeTunes();
            finish("Saved \"" + _pendingName + "\".");
            return;
        }
        var stored = _tunes[_slot] as Tune;
        if (_step == STEP_APPLY_VERIFY) {
            finish(snapshot.equals(_written)
                ? "Applied \"" + stored.name + "\"."
                : "The board did not keep \"" + stored.name + "\". Check its tune in VESC Tool before riding.");
            return;
        }
        // STEP_APPLY_READ
        if (signature != stored.signature) {
            finish("\"" + stored.name + "\" was saved on Refloat " + stored.version + ", the board runs another version. Not applied.");
            return;
        }
        if (stored.bytes.size() != TuneCodec.tuneLength(ranges)) {
            finish("\"" + stored.name + "\" does not fit this board's layout. Not applied.");
            return;
        }
        if (onBoard.bytes.equals(stored.bytes)) {
            finish("\"" + stored.name + "\" is already on the board.");
            return;
        }
        // Checked again right before writing: the rider may have stepped on while we read.
        var refusal = unsafeToWrite();
        if (refusal != null) {
            finish(refusal);
            return;
        }
        var patched = TuneCodec.patch(snapshot, ranges, stored.bytes);
        _written = patched;
        tuneStatus = "Writing \"" + stored.name + "\"…";
        _step = STEP_APPLY_WRITE;
        _board.session.request(ONE_OFF_SET_CONFIG, Vesc.setConfig(patched));
        _board.pump();
    }

    //! A reason not to write now, or null while the board stands still: live data, not engaged, no
    //! footpad pressed, not rolling.
    private function unsafeToWrite() as String? {
        var sample = _board.session.refloat;
        if (sample == null || _board.session.isStale(System.getTimer())) {
            return "No live data from the board. Not applied.";
        }
        if (sample.isEngaged() || sample.footpads() != 0 || sample.speed.abs() > 1.0) {
            return "The board must stand still with nobody on it. Not applied.";
        }
        return null;
    }

    private function start(status as String) as Boolean {
        if (isBusy()) {
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

    //! `status` null keeps the last message (a quiet refresh has nothing to report).
    private function finish(status as String?) as Void {
        if (status != null) {
            tuneStatus = status;
        }
        _step = STEP_IDLE;
        WatchUi.requestUpdate();
    }

    private function versionText() as String {
        var version = _board.refloatVersion;
        return version == null ? "?" : version[0] + "." + version[1];
    }

    private function loadTunes() as Array<Tune?> {
        // The first version kept whole-config snapshots under "tunes"; never write those back.
        Storage.deleteValue("tunes");
        var tunes = new [TUNE_SLOTS] as Array<Tune?>;
        var stored = Storage.getValue(STORAGE_TUNES) as Array<Array?>?;
        if (stored != null) {
            for (var i = 0; i < TUNE_SLOTS && i < stored.size(); i++) {
                var entry = stored[i];
                if (entry != null && entry.size() == 4) {
                    tunes[i] = new Tune(entry[0] as String, entry[1] as Number, entry[2] as ByteArray, entry[3] as String);
                }
            }
        }
        return tunes;
    }

    private function storeTunes() as Void {
        var stored = [] as Array<Storage.ValueType>;
        for (var i = 0; i < TUNE_SLOTS; i++) {
            var tune = _tunes[i];
            stored.add(tune == null ? null : [tune.name, tune.signature, tune.bytes, tune.version] as Array<Storage.ValueType>);
        }
        Storage.setValue(STORAGE_TUNES, stored);
    }
}
