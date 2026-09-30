import Toybox.Lang;

enum SessionPhase {
    PHASE_DISCONNECTED,
    PHASE_FINDING_CONTROLLER, // asking the connected node, then each node on the CAN bus, for Refloat
    PHASE_POLLING
}

//! Where a request goes: the node the watch is connected to, or a CAN id reached through it.
const TARGET_DIRECT = -1;

//! How long a request may go unanswered before the next one is sent anyway.
const REQUEST_TIMEOUT_MS = 1000;
//! Telemetry older than this is shown as stale.
const STALE_AFTER_MS = 2000;
//! One BMS request per this many requests: cells change slowly and the reply is large.
const BMS_EVERY = 8;
//! Unanswered Refloat requests in a row after which the controller is searched for again.
const REDISCOVER_AFTER_TIMEOUTS = 5;
//! Unanswered BMS requests in a row after which the next BMS candidate is tried.
const BMS_GIVE_UP_AFTER = 2;

enum RequestKind {
    REQUEST_PING,
    REQUEST_REFLOAT,
    REQUEST_BMS,
    REQUEST_ONE_OFF
}

//! Requests sent once on demand, ahead of the next poll, always to the controller.
enum OneOffKind {
    ONE_OFF_INFO,
    ONE_OFF_LIGHTS,
    ONE_OFF_GET_CONFIG,
    ONE_OFF_SET_CONFIG
}

//! A config write is hundreds of bytes in 20-byte Bluetooth writes, and the controller saves it to
//! flash before it answers.
const CONFIG_TIMEOUT_MS = 5000;

//! Who hears how a one-off request ended: its reply payload, or null when it timed out or the link
//! went down.
typedef OneOffListener as interface {
    function onOneOffReply(kind as OneOffKind, payload as ByteArray?) as Void;
};

//! What the watch knows about the board and how to reach it, independent of Bluetooth. The link feeds
//! it `connected`, packets and ticks; it answers each tick with the next request to send, if any.
//!
//! The watch may be connected to any VESC node: the controller itself, a Bluetooth bridge or a BMS.
//! The controller is whichever node answers Refloat's ALLDATA — the connected node first, then every
//! node the CAN bus reports. The BMS is found the same way with `COMM_BMS_GET_VALUES`; the connected
//! node answers for it more often than not (a BMS itself, or a controller or bridge relaying what it
//! hears on the bus).
class BoardSession {
    var phase as SessionPhase = PHASE_DISCONNECTED;
    //! TARGET_DIRECT or a CAN id, once found.
    var controllerTarget as Number? = null;
    var refloat as RefloatSample? = null;
    var bms as BmsSample? = null;
    var faultCode as Number? = null;

    private var _knownController as Number?;
    private var _refloatAtMs as Number? = null;
    //! Odometer at the first sample since the app started, for trip distance.
    private var _odometerStart as Double? = null;

    //! Controller candidates still to ask, in order.
    private var _candidates as Array<Number> = [] as Array<Number>;
    //! CAN ids the bus reported, or null before a ping was answered.
    private var _busIds as Array<Number>? = null;
    private var _pingTried as Boolean = false;
    //! The controller id a BMS reported, asked first when searching the bus.
    private var _hintedController as Number? = null;

    //! BMS candidates still to try; the first one is polled. Empty: no BMS found.
    private var _bmsTargets as Array<Number> = [TARGET_DIRECT] as Array<Number>;
    private var _bmsMisses as Number = 0;

    private var _listener as OneOffListener?;
    //! Queued one-offs as [kind, payload]; the first is in flight while `_awaiting` is ONE_OFF.
    private var _oneOffs as Array<[OneOffKind, ByteArray]> = [] as Array<[OneOffKind, ByteArray]>;

    private var _awaiting as RequestKind? = null;
    private var _awaitingSinceMs as Number = 0;
    private var _awaitingTimeoutMs as Number = REQUEST_TIMEOUT_MS;
    private var _requests as Number = 0;
    private var _refloatMisses as Number = 0;

    //! `knownController` (TARGET_DIRECT or a CAN id) skips the search: remembered from an earlier
    //! session, or set by the rider.
    function initialize(knownController as Number?, listener as OneOffListener?) {
        _knownController = knownController;
        _listener = listener;
    }

    //! Queues a one-off request for the controller. It fails (null reply) when no controller is
    //! found yet or the link drops before the reply.
    function request(kind as OneOffKind, payload as ByteArray) as Void {
        if (phase != PHASE_POLLING) {
            fail(kind);
            return;
        }
        _oneOffs.add([kind, payload]);
    }

    function onConnected(nowMs as Number) as Void {
        _awaiting = null;
        _requests = 0;
        _refloatMisses = 0;
        _bmsMisses = 0;
        _bmsTargets = [TARGET_DIRECT] as Array<Number>;
        if (_knownController != null) {
            controllerTarget = _knownController;
            phase = PHASE_POLLING;
        } else {
            startSearch();
        }
    }

    function onDisconnected() as Void {
        phase = PHASE_DISCONNECTED;
        _awaiting = null;
        var pending = _oneOffs;
        _oneOffs = [] as Array<[OneOffKind, ByteArray]>;
        for (var i = 0; i < pending.size(); i++) {
            fail(pending[i][0]);
        }
    }

    //! The next request payload (unframed) to send now, or null to wait.
    function tick(nowMs as Number) as ByteArray? {
        if (phase == PHASE_DISCONNECTED) {
            return null;
        }
        if (_awaiting != null) {
            if (nowMs - _awaitingSinceMs < _awaitingTimeoutMs) {
                return null;
            }
            onTimeout(_awaiting as RequestKind);
            _awaiting = null;
        }
        if (phase == PHASE_FINDING_CONTROLLER) {
            return nextSearchRequest(nowMs);
        }
        if (_oneOffs.size() > 0) {
            var next = _oneOffs[0];
            var timeout = (next[0] == ONE_OFF_GET_CONFIG || next[0] == ONE_OFF_SET_CONFIG) ? CONFIG_TIMEOUT_MS : REQUEST_TIMEOUT_MS;
            var payload = send(REQUEST_ONE_OFF, addressed(controllerTarget as Number, next[1]), nowMs);
            _awaitingTimeoutMs = timeout;
            return payload;
        }
        return nextPollRequest(nowMs);
    }

    function onPacket(raw as ByteArray, nowMs as Number) as Void {
        var payload = Vesc.unwrap(raw);

        if (_awaiting == REQUEST_ONE_OFF && _oneOffs.size() > 0 && answers(_oneOffs[0][0], payload)) {
            var kind = _oneOffs[0][0];
            _oneOffs = _oneOffs.slice(1, null);
            _awaiting = null;
            if (_listener != null) {
                (_listener as OneOffListener).onOneOffReply(kind, payload);
            }
            return;
        }

        var ids = Decoders.pingCan(payload);
        if (ids != null) {
            answered(REQUEST_PING);
            _busIds = ids;
            if (phase == PHASE_FINDING_CONTROLLER) {
                _candidates = orderedBusIds(ids);
            }
            refillBmsTargets();
            return;
        }

        var bmsSample = Decoders.bmsValues(payload);
        if (bmsSample != null) {
            answered(REQUEST_BMS);
            _bmsMisses = 0;
            bms = bmsSample;
            _hintedController = bmsSample.controllerId;
            return;
        }

        var result = Decoders.refloatAllData(payload);
        if (result == null) {
            return;
        }
        if (phase == PHASE_FINDING_CONTROLLER && _awaiting != REQUEST_REFLOAT) {
            // A late reply from a candidate already given up on: its sender is unknown now.
            return;
        }
        answered(REQUEST_REFLOAT);
        _refloatMisses = 0;
        if (phase == PHASE_FINDING_CONTROLLER) {
            // Replies carry no sender, but only one request is out: the candidate just asked.
            controllerTarget = _candidates.size() > 0 ? _candidates[0] : TARGET_DIRECT;
            phase = PHASE_POLLING;
        }
        if (result instanceof Number) {
            faultCode = result;
        } else {
            faultCode = null;
            refloat = result as RefloatSample;
            _refloatAtMs = nowMs;
            if (_odometerStart == null && refloat.odometer != null) {
                _odometerStart = refloat.odometer;
            }
        }
    }

    //! Metres ridden since the app started, from the controller's odometer; null before mode-2 data.
    function tripMeters() as Double? {
        var sample = refloat;
        if (sample == null || sample.odometer == null || _odometerStart == null) {
            return null;
        }
        return (sample.odometer as Double) - (_odometerStart as Double);
    }

    function isStale(nowMs as Number) as Boolean {
        return _refloatAtMs == null || nowMs - (_refloatAtMs as Number) > STALE_AFTER_MS;
    }

    private function nextSearchRequest(nowMs as Number) as ByteArray? {
        if (_candidates.size() > 0) {
            return send(REQUEST_REFLOAT, addressed(_candidates[0], Vesc.refloatAllData()), nowMs);
        }
        if (!_pingTried) {
            _pingTried = true;
            return send(REQUEST_PING, Vesc.pingCan(), nowMs);
        }
        // Nobody answered: start over, the board may still be booting.
        startSearch();
        return send(REQUEST_REFLOAT, addressed(_candidates[0], Vesc.refloatAllData()), nowMs);
    }

    private function nextPollRequest(nowMs as Number) as ByteArray? {
        _requests += 1;
        if (_requests % BMS_EVERY == 0) {
            if (_bmsTargets.size() > 0) {
                return send(REQUEST_BMS, addressed(_bmsTargets[0], Vesc.bmsGetValues()), nowMs);
            }
            if (_busIds == null && !_pingTried) {
                // The BMS did not answer through the connected node; learn the bus to try it directly.
                _pingTried = true;
                return send(REQUEST_PING, Vesc.pingCan(), nowMs);
            }
        }
        return send(REQUEST_REFLOAT, addressed(controllerTarget as Number, Vesc.refloatAllData()), nowMs);
    }

    private function onTimeout(kind as RequestKind) as Void {
        if (kind == REQUEST_ONE_OFF) {
            if (_oneOffs.size() > 0) {
                var failed = _oneOffs[0][0];
                _oneOffs = _oneOffs.slice(1, null);
                fail(failed);
            }
            return;
        }
        if (kind == REQUEST_PING) {
            // This node cannot ping the bus; the connected node is the only candidate then.
            if (_busIds == null) {
                _busIds = [] as Array<Number>;
            }
            refillBmsTargets();
            return;
        }
        if (kind == REQUEST_BMS) {
            _bmsMisses += 1;
            if (_bmsMisses >= BMS_GIVE_UP_AFTER) {
                _bmsMisses = 0;
                _bmsTargets = _bmsTargets.slice(1, null);
                refillBmsTargets();
            }
            return;
        }
        if (phase == PHASE_FINDING_CONTROLLER) {
            // That candidate is not the controller; ask the next one.
            if (_candidates.size() > 0) {
                _candidates = _candidates.slice(1, null);
            }
            return;
        }
        _refloatMisses += 1;
        if (_refloatMisses >= REDISCOVER_AFTER_TIMEOUTS) {
            // A remembered or configured target that stopped answering; the bus may have changed.
            _knownController = null;
            startSearch();
        }
    }

    //! After the connected node failed as BMS, try the other bus nodes once the bus is known.
    private function refillBmsTargets() as Void {
        if (_bmsTargets.size() > 0 || _busIds == null) {
            return;
        }
        var ids = _busIds as Array<Number>;
        for (var i = 0; i < ids.size(); i++) {
            if (ids[i] != controllerTarget) {
                _bmsTargets.add(ids[i]);
            }
        }
    }

    private function startSearch() as Void {
        phase = PHASE_FINDING_CONTROLLER;
        controllerTarget = null;
        _refloatMisses = 0;
        _pingTried = false;
        _candidates = [TARGET_DIRECT] as Array<Number>;
    }

    //! The id a BMS named as its controller goes first.
    private function orderedBusIds(ids as Array<Number>) as Array<Number> {
        var ordered = [] as Array<Number>;
        if (_hintedController != null && ids.indexOf(_hintedController as Number) >= 0) {
            ordered.add(_hintedController as Number);
        }
        for (var i = 0; i < ids.size(); i++) {
            if (ordered.indexOf(ids[i]) < 0) {
                ordered.add(ids[i]);
            }
        }
        return ordered;
    }

    private function addressed(target as Number, payload as ByteArray) as ByteArray {
        return target == TARGET_DIRECT ? payload : Vesc.forwardCan(target, payload);
    }

    private function send(kind as RequestKind, payload as ByteArray, nowMs as Number) as ByteArray {
        _awaiting = kind;
        _awaitingSinceMs = nowMs;
        _awaitingTimeoutMs = REQUEST_TIMEOUT_MS;
        return payload;
    }

    private function answers(kind as OneOffKind, payload as ByteArray) as Boolean {
        if (kind == ONE_OFF_INFO) {
            return Decoders.refloatVersion(payload) != null;
        }
        if (kind == ONE_OFF_LIGHTS) {
            return Decoders.lightsEcho(payload) != null;
        }
        if (kind == ONE_OFF_GET_CONFIG) {
            return Decoders.configSnapshot(payload) != null;
        }
        return Decoders.isConfigWritten(payload);
    }

    private function fail(kind as OneOffKind) as Void {
        if (_listener != null) {
            (_listener as OneOffListener).onOneOffReply(kind, null);
        }
    }

    //! A reply only clears the wait when it is what we asked for; a late reply to an earlier
    //! request must not release the one now in flight.
    private function answered(kind as RequestKind) as Void {
        if (_awaiting == kind) {
            _awaiting = null;
        }
    }
}
