import Toybox.Application.Properties;
import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

const STORAGE_CONTROLLER = "controllerId";
const STORAGE_BOARD_NAME = "boardName";
//! A held remote tilt is repeated this often; Refloat drops the input after about a second.
const TILT_REPEAT_MS = 200;
//! Neutral is sent this many times after a tilt ends, then the stream stops.
const TILT_NEUTRAL_REPEATS = 3;

//! The board as both apps see it: a Bluetooth link to one VESC node and the session that knows what
//! to ask it. Requests are driven by the link itself — a reply or a finished write sends the next
//! one — so the rate follows the link, and a data field (which gets no timers) runs the same loop.
//! `pump` must also be called now and then from outside, so an unanswered request times out.
class Board {
    var session as BoardSession;
    var link as BleLink;
    //! Refloat [major, minor], once the controller has said.
    var refloatVersion as [Number, Number] or Null = null;
    //! Remote tilt input being held, 0..255 (Vesc.TILT_CENTER is none).
    var tilt as Number = Vesc.TILT_CENTER;
    //! Hears replies to one-off requests other than the version read (lights, config).
    var controls as OneOffListener? = null;

    private var _versionRequested as Boolean = false;
    private var _tiltSentAtMs as Number = 0;
    private var _neutralRepeats as Number = 0;
    private var _autoPairAny as Boolean;
    private var _configuredName as String?;

    //! `autoPairAny`: with no name to look for, take the first VESC device found (a data field
    //! cannot show a picker). `configuredName` is the rider's setting; otherwise the device this app
    //! connected to last is looked for by name.
    function initialize(autoPairAny as Boolean, configuredName as String?) {
        _autoPairAny = autoPairAny;
        _configuredName = (configuredName != null && !configuredName.equals("")) ? configuredName : null;
        var preferred = _configuredName != null ? _configuredName : Storage.getValue(STORAGE_BOARD_NAME) as String?;
        session = new BoardSession(knownController(), self);
        link = new BleLink(self, autoPairAny, preferred);
    }

    function start() as Void {
        link.start();
    }

    function stop() as Void {
        link.stop();
    }

    //! Sends the session's next request if the link can take one, and gives up on a connection that
    //! is not coming up.
    function pump() as Void {
        var now = System.getTimer();
        link.check(now);
        if (!link.canSend()) {
            return;
        }
        // The tilt stream goes first: it has no reply and must not lapse behind telemetry.
        if (tiltDue(now)) {
            link.send(Vesc.remoteTilt(tilt));
            _tiltSentAtMs = now;
            if (tilt == Vesc.TILT_CENTER) {
                _neutralRepeats -= 1;
            }
            return;
        }
        var request = session.tick(now);
        if (request != null) {
            link.send(request);
        }
    }

    //! Holds remote tilt at `value` (0..255) until changed; Vesc.TILT_CENTER releases it. Streamed
    //! only while connected: when the app closes or the link drops, Refloat lets go within a second.
    function setTilt(value as Number) as Void {
        tilt = value < 0 ? 0 : (value > 255 ? 255 : value);
        if (tilt == Vesc.TILT_CENTER) {
            _neutralRepeats = TILT_NEUTRAL_REPEATS;
        }
        _tiltSentAtMs = 0;
        pump();
    }

    //! Refloat before 1.2 switches lights with a different command.
    function legacyLights() as Boolean {
        var version = refloatVersion;
        return version != null && (version[0] < 1 || (version[0] == 1 && version[1] < 2));
    }

    function onOneOffReply(kind as OneOffKind, payload as ByteArray?) as Void {
        if (kind == ONE_OFF_INFO) {
            refloatVersion = payload != null ? Decoders.refloatVersion(payload) : null;
            return;
        }
        if (controls != null) {
            (controls as OneOffListener).onOneOffReply(kind, payload);
        }
    }

    private function tiltDue(now as Number) as Boolean {
        if (tilt == Vesc.TILT_CENTER && _neutralRepeats <= 0) {
            return false;
        }
        return session.phase == PHASE_POLLING && now - _tiltSentAtMs >= TILT_REPEAT_MS;
    }

    //! Null while live; otherwise what the rider is waiting for, short enough for a field label.
    function status(nowMs as Number) as String? {
        if (link.state == LINK_REGISTERING) {
            return "STARTING";
        }
        if (link.isWaiting()) {
            // Known board not advertising: out of range, off, or held by the other Float Dash app.
            return "WAITING FOR BOARD";
        }
        if (link.state == LINK_SCANNING) {
            // Only the watch app can pick; a data field keeps scanning for its match.
            return (!_autoPairAny && link.found.size() > 0) ? "PICK BOARD" : "SCANNING";
        }
        if (link.state == LINK_CONNECTING) {
            return "CONNECTING";
        }
        if (session.phase == PHASE_FINDING_CONTROLLER) {
            return "FINDING CONTROLLER";
        }
        if (session.faultCode != null) {
            return "FAULT " + session.faultCode;
        }
        if (session.isStale(nowMs)) {
            return "STALE";
        }
        return null;
    }

    //! Switching boards: forget the device, and where the controller was on the old one.
    function forget() as Void {
        Storage.deleteValue(STORAGE_CONTROLLER);
        Storage.deleteValue(STORAGE_BOARD_NAME);
        link.preferredName = _configuredName;
        session = new BoardSession(configuredController(), self);
        refloatVersion = null;
        _versionRequested = false;
        link.rescan();
    }

    function onLinkUp() as Void {
        // Remember the device by name so the next start finds it without asking.
        if (link.pairedName != null) {
            Storage.setValue(STORAGE_BOARD_NAME, link.pairedName);
            link.preferredName = link.pairedName;
        }
        session.onConnected(System.getTimer());
        pump();
    }

    function onLinkDown() as Void {
        // Nothing to stream to; Refloat has already dropped the input by the time we reconnect.
        tilt = Vesc.TILT_CENTER;
        _neutralRepeats = 0;
        _versionRequested = false;
        session.onDisconnected();
    }

    function onLinkWritable() as Void {
        pump();
    }

    function onLinkPacket(payload as ByteArray) as Void {
        var before = session.controllerTarget;
        session.onPacket(payload, System.getTimer());
        if (session.controllerTarget != null && session.controllerTarget != before) {
            Storage.setValue(STORAGE_CONTROLLER, session.controllerTarget);
        }
        if (session.phase == PHASE_POLLING && !_versionRequested) {
            _versionRequested = true;
            session.request(ONE_OFF_INFO, Vesc.refloatInfo());
        }
        pump();
        WatchUi.requestUpdate();
    }

    //! The rider's CAN id setting wins; otherwise where the controller was found on an earlier run
    //! (TARGET_DIRECT or a CAN id), if anywhere.
    private function knownController() as Number? {
        var configured = configuredController();
        if (configured != null) {
            return configured;
        }
        return Storage.getValue(STORAGE_CONTROLLER) as Number?;
    }

    private function configuredController() as Number? {
        var value = Properties.getValue("controllerCanId") as Number?;
        return (value == null || value < 0 || value > 254) ? null : value;
    }
}
