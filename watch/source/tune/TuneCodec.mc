import Toybox.Lang;

//! Takes the tune out of a Refloat config snapshot (`[signature:u32][config]`, as the board reads it)
//! and puts one back in, touching nothing else: lights, battery, faults and remote settings stay as
//! the board has them. Which bytes are the tune comes from TuneLayouts, per config signature.
module TuneCodec {
    function signature(snapshot as ByteArray) as Number {
        return snapshot.decodeNumber(Lang.NUMBER_FORMAT_SINT32, { :offset => 0, :endianness => Lang.ENDIAN_BIG }) as Number;
    }

    //! The layout for this snapshot, or null if its signature is unknown or its length does not
    //! match what that signature describes (then it is not the config we think it is).
    function layoutOf(snapshot as ByteArray) as [Number, Array<Number>] or Null {
        if (snapshot.size() < 4) {
            return null;
        }
        var layout = TuneLayouts.find(signature(snapshot));
        if (layout == null || snapshot.size() != 4 + layout[0]) {
            return null;
        }
        return layout;
    }

    //! The tune bytes: every tune range, concatenated.
    function extract(snapshot as ByteArray, ranges as Array<Number>) as ByteArray {
        var tune = []b;
        for (var i = 0; i < ranges.size(); i += 2) {
            var start = 4 + ranges[i];
            tune.addAll(snapshot.slice(start, start + ranges[i + 1]));
        }
        return tune;
    }

    //! A copy of `snapshot` with its tune ranges replaced by `tune` (as `extract` made it).
    function patch(snapshot as ByteArray, ranges as Array<Number>, tune as ByteArray) as ByteArray {
        var out = snapshot.slice(0, null);
        var from = 0;
        for (var i = 0; i < ranges.size(); i += 2) {
            var start = 4 + ranges[i];
            for (var j = 0; j < ranges[i + 1]; j++) {
                out[start + j] = tune[from + j];
            }
            from += ranges[i + 1];
        }
        return out;
    }

    function tuneLength(ranges as Array<Number>) as Number {
        var total = 0;
        for (var i = 1; i < ranges.size(); i += 2) {
            total += ranges[i];
        }
        return total;
    }
}
