import Toybox.Lang;
import Toybox.Test;

//! Refloat 1.2.x: 272 config bytes, tune in [0,14) [63,75) [100,171).
const REFLOAT_12_SIGNATURE = -1867011654;

function refloat12Snapshot(fill as Number) as ByteArray {
    var snapshot = new [4 + 272]b;
    snapshot.encodeNumber(REFLOAT_12_SIGNATURE, Lang.NUMBER_FORMAT_SINT32, { :offset => 0, :endianness => Lang.ENDIAN_BIG });
    for (var i = 4; i < snapshot.size(); i++) {
        snapshot[i] = fill;
    }
    return snapshot;
}

(:test)
function findsTheLayoutOfAKnownRefloat(logger as Logger) as Boolean {
    var layout = TuneCodec.layoutOf(refloat12Snapshot(0)) as [Number, Array<Number>];
    Test.assertEqual(layout[0], 272);
    Test.assertEqual(TuneCodec.tuneLength(layout[1]), 14 + 12 + 71);
    return true;
}

(:test)
function refusesAConfigOfTheWrongLength(logger as Logger) as Boolean {
    var short = refloat12Snapshot(0).slice(0, 200);
    Test.assert(TuneCodec.layoutOf(short) == null);
    var unknown = refloat12Snapshot(0);
    unknown[0] = unknown[0] ^ 0xFF;
    Test.assert(TuneCodec.layoutOf(unknown) == null);
    return true;
}

(:test)
function patchesOnlyTheTuneFields(logger as Logger) as Boolean {
    var board = refloat12Snapshot(0x11);
    var ranges = (TuneCodec.layoutOf(board) as [Number, Array<Number>])[1];
    var saved = TuneCodec.extract(refloat12Snapshot(0x22), ranges);
    var patched = TuneCodec.patch(board, ranges, saved);

    // Tune bytes come from the saved tune...
    Test.assertEqual(patched[4 + 0], 0x22);
    Test.assertEqual(patched[4 + 70], 0x22);
    Test.assertEqual(patched[4 + 170], 0x22);
    // ...everything else (lights, battery, faults, remote) stays as the board had it.
    Test.assertEqual(patched[4 + 14], 0x11);
    Test.assertEqual(patched[4 + 99], 0x11);
    Test.assertEqual(patched[4 + 171], 0x11);
    Test.assertEqual(patched[4 + 271], 0x11);
    Test.assert(patched.slice(0, 4).equals(board.slice(0, 4)));
    Test.assert(TuneCodec.extract(patched, ranges).equals(saved));
    // The board's own snapshot is left alone.
    Test.assertEqual(board[4], 0x11);
    return true;
}
