import Toybox.Application.Properties;
import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

const STORAGE_CONTROLLER = "controllerId";

//! The board as both apps see it: a Bluetooth link to one VESC node and the session that knows what
//! to ask it. Requests are driven by the link itself — a reply or a finished write sends the next
//! one — so the rate follows the link, and a data field (which gets no timers) runs the same loop.
//! `pump` must also be called now and then from outside, so an unanswered request times out.
class Board {
    var session as BoardSession;
    var link as BleLink;
    private var _autoPair as Boolean;

    //! `autoPair`: connect to the first matching device without asking (a data field cannot show a
    //! picker). `preferredName` narrows that to one device name.
    function initialize(autoPair as Boolean, preferredName as String?) {
        _autoPair = autoPair;
        session = new BoardSession(knownController());
        link = new BleLink(self, autoPair, preferredName);
    }

    function start() as Void {
        link.start();
    }

    function stop() as Void {
        link.stop();
    }

    //! Sends the session's next request if the link can take one.
    function pump() as Void {
        if (link.canSend()) {
            var request = session.tick(System.getTimer());
            if (request != null) {
                link.send(request);
            }
        }
    }

    //! Null while live; otherwise what the rider is waiting for, short enough for a field label.
    function status(nowMs as Number) as String? {
        if (link.state == LINK_REGISTERING) {
            return "STARTING";
        }
        if (link.state == LINK_SCANNING) {
            // Only the watch app can pick; a data field keeps scanning for its match.
            return (!_autoPair && link.found.size() > 0) ? "PICK BOARD" : "SCANNING";
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

    //! Switching boards: forget the pairing and where the controller was on the old one.
    function forget() as Void {
        Storage.deleteValue(STORAGE_CONTROLLER);
        session = new BoardSession(configuredController());
        link.rescan();
    }

    function onLinkUp() as Void {
        session.onConnected(System.getTimer());
        pump();
    }

    function onLinkDown() as Void {
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
