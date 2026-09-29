import Toybox.Lang;
import Toybox.Test;

//! Vectors mirror Vescape's VescProtocolTest, so both decoders agree on the same bytes.

(:test)
function frameRoundTripsSplitAcrossNotifications(logger as Logger) as Boolean {
    var payload = Vesc.refloatAllData();
    var frame = Vesc.frame(payload);
    var reassembler = new Reassembler();
    Test.assertEqual(reassembler.feed(frame.slice(0, 3)).size(), 0);
    var packets = reassembler.feed(frame.slice(3, null));
    Test.assertEqual(packets.size(), 1);
    Test.assert(packets[0].equals(payload));
    return true;
}

(:test)
function reassemblerSkipsNoiseAndBadCrc(logger as Logger) as Boolean {
    var good = Vesc.frame([Vesc.COMM_PING_CAN, 10]b);
    var bad = Vesc.frame([Vesc.COMM_PING_CAN, 11]b);
    bad[bad.size() - 2] = bad[bad.size() - 2] ^ 0xFF;
    var stream = [0x55, 0x00]b;
    stream.addAll(bad);
    stream.addAll(good);
    var packets = new Reassembler().feed(stream);
    Test.assertEqual(packets.size(), 1);
    Test.assert(packets[0].equals([Vesc.COMM_PING_CAN, 10]b));
    return true;
}

(:test)
function forwardsOverCan(logger as Logger) as Boolean {
    Test.assert(Vesc.forwardCan(7, Vesc.refloatAllData()).equals([34, 7, 36, 101, 10, 2]b));
    Test.assert(Vesc.unwrap([34, 7, 36, 101]b).equals([36, 101]b));
    return true;
}

(:test)
function decodesRefloatAllData(logger as Logger) as Boolean {
    var payload = allDataPayload();
    put16(payload, 8, -67);
    payload[10] = 1;
    put16(payload, 20, 91);
    put16(payload, 23, 776);
    put16(payload, 27, -123);
    payload[33] = 178;
    payload.encodeNumber(0x3f800000, Lang.NUMBER_FORMAT_UINT32, { :offset => 35, :endianness => Lang.ENDIAN_BIG });
    payload[39] = 80;
    payload[40] = 100;

    var sample = Decoders.refloatAllData(payload) as RefloatSample;
    assertNear(sample.roll, -6.7);
    assertNear(sample.pitch, 9.1);
    assertNear(sample.batteryVoltage, 77.6);
    assertNear(sample.speed, -44.28);
    assertNear(sample.duty, 0.5);
    assertNear((sample.odometer as Double).toFloat(), 1.0);
    assertNear(sample.mosfetTemp as Float, 40.0);
    assertNear(sample.motorTemp as Float, 50.0);
    Test.assert(sample.isEngaged());
    return true;
}

(:test)
function clampsIdleDutyNoise(logger as Logger) as Boolean {
    var payload = allDataPayload();
    payload[33] = 129;
    assertNear((Decoders.refloatAllData(payload) as RefloatSample).duty, 0.0);
    payload[33] = 130;
    assertNear((Decoders.refloatAllData(payload) as RefloatSample).duty, 0.02);
    return true;
}

(:test)
function reportsRefloatFault(logger as Logger) as Boolean {
    Test.assertEqual(Decoders.refloatAllData([36, 101, 10, 69, 7]b) as Number, 7);
    return true;
}

(:test)
function decodesBmsValues(logger as Logger) as Boolean {
    // Three cells, one temperature sensor, then SoC and SoH as float16 x1000 and the controller id,
    // as `vesc_bms_fw` sends them.
    var payload = new [51]b;
    payload[0] = Vesc.COMM_BMS_GET_VALUES;
    put32(payload, 1, 60000000);
    put32(payload, 9, 5000000);
    payload[25] = 3;
    put16(payload, 26, 3650);
    put16(payload, 28, 3700);
    put16(payload, 30, 3680);
    payload[33] = 1;
    payload[35] = 1;
    put16(payload, 36, 2530);
    put16(payload, 46, 853);
    put16(payload, 48, 990);
    payload[50] = 7;

    var bms = Decoders.bmsValues(payload) as BmsSample;
    assertNear(bms.packVoltage, 60.0);
    assertNear(bms.current, 5.0);
    assertNear(bms.cellMin as Float, 3.65);
    assertNear(bms.cellMax as Float, 3.70);
    assertNear(bms.soc as Float, 0.853);
    Test.assertEqual(bms.controllerId as Number, 7);
    return true;
}

(:test)
function ignoresAnImplausibleBmsSoc(logger as Logger) as Boolean {
    var payload = new [43]b;
    payload[0] = Vesc.COMM_BMS_GET_VALUES;
    payload[25] = 1;
    put16(payload, 26, 3600);
    put16(payload, 38, 4000);
    Test.assert((Decoders.bmsValues(payload) as BmsSample).soc == null);
    return true;
}

(:test)
function decodesCanPing(logger as Logger) as Boolean {
    var ids = Decoders.pingCan([Vesc.COMM_PING_CAN, 10, 124]b) as Array<Number>;
    Test.assertEqual(ids.size(), 2);
    Test.assertEqual(ids[1], 124);
    Test.assert(Decoders.pingCan([Vesc.COMM_FW_VERSION]b) == null);
    return true;
}

function allDataPayload() as ByteArray {
    var payload = new [42]b;
    payload[0] = Vesc.COMM_CUSTOM_APP_DATA;
    payload[1] = Vesc.REFLOAT_MAGIC;
    payload[2] = Vesc.REFLOAT_GET_ALLDATA;
    payload[3] = 2;
    payload[33] = 128;
    return payload;
}

function put16(bytes as ByteArray, offset as Number, value as Number) as Void {
    bytes.encodeNumber(value, Lang.NUMBER_FORMAT_SINT16, { :offset => offset, :endianness => Lang.ENDIAN_BIG });
}

function put32(bytes as ByteArray, offset as Number, value as Number) as Void {
    bytes.encodeNumber(value, Lang.NUMBER_FORMAT_SINT32, { :offset => offset, :endianness => Lang.ENDIAN_BIG });
}

function assertNear(actual as Float, expected as Float) as Void {
    Test.assertMessage((actual - expected).abs() < 0.001, "expected " + expected + ", got " + actual);
}
