import Toybox.Lang;
import Toybox.Test;

(:test)
function usesTheConnectedNodeWhenItIsTheController(logger as Logger) as Boolean {
    var session = new BoardSession(null);
    session.onConnected(0);
    Test.assert(sends(session.tick(0), Vesc.refloatAllData()));
    session.onPacket(allDataPayload(), 50);
    Test.assertEqual(session.phase, PHASE_POLLING);
    Test.assertEqual(session.controllerTarget as Number, TARGET_DIRECT);
    Test.assert(sends(session.tick(100), Vesc.refloatAllData()));
    return true;
}

(:test)
function searchesTheBusWhenTheConnectedNodeIsNotTheController(logger as Logger) as Boolean {
    var session = new BoardSession(null);
    session.onConnected(0);
    session.tick(0);
    // The connected node stays silent: ping the bus, then ask node 5 (silent) and node 9.
    Test.assert(sends(session.tick(REQUEST_TIMEOUT_MS), Vesc.pingCan()));
    session.onPacket([Vesc.COMM_PING_CAN, 5, 9]b, 1100);
    Test.assert(sends(session.tick(1200), Vesc.forwardCan(5, Vesc.refloatAllData())));
    Test.assert(sends(session.tick(2200), Vesc.forwardCan(9, Vesc.refloatAllData())));
    session.onPacket(allDataPayload(), 2300);
    Test.assertEqual(session.controllerTarget as Number, 9);
    Test.assert(!session.isStale(2300));
    return true;
}

(:test)
function ignoresRefloatDataWhileWaitingForThePing(logger as Logger) as Boolean {
    var session = new BoardSession(null);
    session.onConnected(0);
    session.tick(0);
    Test.assert(sends(session.tick(REQUEST_TIMEOUT_MS), Vesc.pingCan()));
    // A slow reply to the abandoned direct request: nothing is waiting for Refloat data now.
    session.onPacket(allDataPayload(), REQUEST_TIMEOUT_MS + 50);
    Test.assertEqual(session.phase, PHASE_FINDING_CONTROLLER);
    return true;
}

(:test)
function asksTheControllerTheBmsNamesFirst(logger as Logger) as Boolean {
    var fresh = new BoardSession(null);
    fresh.onConnected(0);
    fresh.onPacket(bmsPayload(9), 10);
    fresh.tick(0);
    fresh.tick(REQUEST_TIMEOUT_MS);
    fresh.onPacket([Vesc.COMM_PING_CAN, 5, 9]b, 1100);
    Test.assert(sends(fresh.tick(1200), Vesc.forwardCan(9, Vesc.refloatAllData())));
    return true;
}

(:test)
function pollsTheBmsEveryEighthRequest(logger as Logger) as Boolean {
    var session = new BoardSession(4);
    session.onConnected(0);
    var bmsRequests = 0;
    for (var i = 0; i < 16; i++) {
        var request = session.tick(i * 100) as ByteArray;
        if (request.equals(Vesc.bmsGetValues())) {
            bmsRequests += 1;
            session.onPacket(bmsPayload(4), i * 100 + 50);
        } else {
            Test.assert(request.equals(Vesc.forwardCan(4, Vesc.refloatAllData())));
            session.onPacket(allDataPayload(), i * 100 + 50);
        }
    }
    Test.assertEqual(bmsRequests, 2);
    assertNear((session.bms as BmsSample).soc as Float, 0.85);
    return true;
}

(:test)
function triesTheOtherBusNodesWhenTheConnectedNodeIsNoBms(logger as Logger) as Boolean {
    var session = new BoardSession(4);
    session.onConnected(0);
    var now = 0;
    var bmsSeen = [] as Array<ByteArray>;
    // Answer every Refloat request, ignore every BMS request, answer the ping with nodes 4 and 12.
    for (var i = 0; i < 40; i++) {
        var request = session.tick(now);
        if (request != null) {
            if (request.equals(Vesc.pingCan())) {
                session.onPacket([Vesc.COMM_PING_CAN, 4, 12]b, now + 10);
            } else if (request.equals(Vesc.forwardCan(4, Vesc.refloatAllData()))) {
                session.onPacket(allDataPayload(), now + 10);
            } else {
                bmsSeen.add(request);
            }
        }
        now += REQUEST_TIMEOUT_MS;
    }
    Test.assert(bmsSeen[0].equals(Vesc.bmsGetValues()));
    Test.assert(bmsSeen[bmsSeen.size() - 1].equals(Vesc.forwardCan(12, Vesc.bmsGetValues())));
    return true;
}

(:test)
function waitsForTheReplyBeforeTheNextRequest(logger as Logger) as Boolean {
    var session = new BoardSession(4);
    session.onConnected(0);
    Test.assert(session.tick(0) != null);
    Test.assert(session.tick(100) == null);
    session.onPacket(allDataPayload(), 150);
    Test.assert(session.tick(200) != null);
    return true;
}

(:test)
function searchesAgainWhenTheRememberedControllerGoesQuiet(logger as Logger) as Boolean {
    var session = new BoardSession(4);
    session.onConnected(0);
    session.tick(0);
    var request = null;
    // Each later tick times the previous request out; the last miss starts the search over.
    for (var i = 1; i <= REDISCOVER_AFTER_TIMEOUTS; i++) {
        request = session.tick(i * REQUEST_TIMEOUT_MS);
    }
    Test.assertEqual(session.phase, PHASE_FINDING_CONTROLLER);
    Test.assert(sends(request, Vesc.refloatAllData()));
    return true;
}

(:test)
function goesStaleWithoutTelemetry(logger as Logger) as Boolean {
    var session = new BoardSession(4);
    session.onConnected(0);
    session.tick(0);
    session.onPacket(allDataPayload(), 100);
    Test.assert(!session.isStale(100 + STALE_AFTER_MS));
    Test.assert(session.isStale(101 + STALE_AFTER_MS));
    return true;
}

//! A one-cell, no-sensor BMS reply at 85 % naming `controllerId`.
function bmsPayload(controllerId as Number) as ByteArray {
    // id · 6 x f32 · cells=1 · cell · bal · temps=0 · 4 x f16 · soc · soh · controller id
    var payload = new [43]b;
    payload[0] = Vesc.COMM_BMS_GET_VALUES;
    payload[25] = 1;
    put16(payload, 26, 3600);
    put16(payload, 38, 850);
    payload[42] = controllerId;
    return payload;
}

//! Whether a tick produced exactly this request.
function sends(request as ByteArray?, expected as ByteArray) as Boolean {
    return request != null && request.equals(expected);
}
