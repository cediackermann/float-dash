import Toybox.Lang;
import Toybox.Math;

//! VESC command ids used here. Values from the VESC firmware `datatypes.h`.
module Vesc {
    const COMM_FW_VERSION = 0;
    const COMM_FORWARD_CAN = 34;
    const COMM_CUSTOM_APP_DATA = 36;
    const COMM_SET_CHUCK_DATA = 35;
    const COMM_PING_CAN = 62;
    const COMM_GET_CUSTOM_CONFIG = 93;
    const COMM_SET_CUSTOM_CONFIG = 95;
    const COMM_BMS_GET_VALUES = 96;

    //! Custom config index of the Refloat package.
    const REFLOAT_CONFIG = 0;
    const REFLOAT_MAGIC = 101;
    const REFLOAT_GET_INFO = 0;
    const REFLOAT_GET_ALLDATA = 10;
    //! Lights switch from Refloat 1.2 (uint32 mask); 1.0-1.1 used 202 with a one-byte mask.
    const REFLOAT_LIGHTS_CONTROL = 20;
    const REFLOAT_LIGHTS_CONTROL_LEGACY = 202;
    const LIGHT_LEDS = 0x1;
    const LIGHT_HEADLIGHTS = 0x2;
    //! Remote tilt neutral on the 0..255 input scale.
    const TILT_CENTER = 128;
    //! Mode 2 adds odometer and temperatures to the realtime fields.
    const REFLOAT_ALLDATA_MODE = 2;
    const REFLOAT_FAULT_MODE = 69;

    //! CRC-16/XMODEM (poly 0x1021, init 0) over `data[start, end)`, as VESC frames it.
    function crc16(data as ByteArray, start as Number, end as Number) as Number {
        var crc = 0;
        for (var i = start; i < end; i++) {
            crc = crc ^ (data[i] << 8);
            for (var bit = 0; bit < 8; bit++) {
                if ((crc & 0x8000) != 0) {
                    crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
                } else {
                    crc = (crc << 1) & 0xFFFF;
                }
            }
        }
        return crc;
    }

    //! Wraps a payload in a VESC frame: `[0x02][len]` up to 255 bytes, `[0x03][len hi][len lo]` above
    //! (a config write), then `[payload][crc hi][crc lo][0x03]`.
    function frame(payload as ByteArray) as ByteArray {
        var size = payload.size();
        var crc = crc16(payload, 0, size);
        var out = size <= 255 ? [0x02, size]b : [0x03, (size >> 8) & 0xFF, size & 0xFF]b;
        out.addAll(payload);
        out.addAll([(crc >> 8) & 0xFF, crc & 0xFF, 0x03]b);
        return out;
    }

    //! Addresses a command to another node on the CAN bus through the node we are connected to.
    function forwardCan(canId as Number, payload as ByteArray) as ByteArray {
        var out = [COMM_FORWARD_CAN, canId]b;
        out.addAll(payload);
        return out;
    }

    function pingCan() as ByteArray {
        return [COMM_PING_CAN]b;
    }

    function refloatAllData() as ByteArray {
        return [COMM_CUSTOM_APP_DATA, REFLOAT_MAGIC, REFLOAT_GET_ALLDATA, REFLOAT_ALLDATA_MODE]b;
    }

    function bmsGetValues() as ByteArray {
        return [COMM_BMS_GET_VALUES]b;
    }

    //! INFO v2 carries major, minor and patch; older packages answer in the v1 layout anyway.
    function refloatInfo() as ByteArray {
        return [COMM_CUSTOM_APP_DATA, REFLOAT_MAGIC, REFLOAT_GET_INFO, 2]b;
    }

    function getConfig() as ByteArray {
        return [COMM_GET_CUSTOM_CONFIG, REFLOAT_CONFIG]b;
    }

    //! `snapshot` is what `getConfig` returned after the command and index: the package signature
    //! (uint32) followed by the encoded config.
    function setConfig(snapshot as ByteArray) as ByteArray {
        var out = [COMM_SET_CUSTOM_CONFIG, REFLOAT_CONFIG]b;
        out.addAll(snapshot);
        return out;
    }

    //! Switches one light (`LIGHT_LEDS` or `LIGHT_HEADLIGHTS`). The mask names only that switch, so
    //! the other keeps whatever state it has. `legacy`: Refloat older than 1.2.
    function lights(light as Number, on as Boolean, legacy as Boolean) as ByteArray {
        var value = on ? light : 0;
        return legacy
            ? [COMM_CUSTOM_APP_DATA, REFLOAT_MAGIC, REFLOAT_LIGHTS_CONTROL_LEGACY, light, value]b
            : [COMM_CUSTOM_APP_DATA, REFLOAT_MAGIC, REFLOAT_LIGHTS_CONTROL, 0, 0, 0, light, value]b;
    }

    //! Remote tilt input, sent as Nunchuk data that Refloat reads as its UART remote (when the tune
    //! has `inputtilt_remote_type` = UART). `value` 0..255, 128 neutral; the wire Y axis is inverted.
    //! Refloat drops the input after about a second without a repeat. No reply.
    function remoteTilt(value as Number) as ByteArray {
        return [COMM_SET_CHUCK_DATA, 0, 255 - value]b;
    }

    //! A forwarded reply usually arrives with the forward prefix already stripped. Some bridges keep
    //! it, so a `[FORWARD_CAN, id, ...]` payload is unwrapped to what the node actually said.
    function unwrap(payload as ByteArray) as ByteArray {
        if (payload.size() > 2 && payload[0] == COMM_FORWARD_CAN) {
            return payload.slice(2, null);
        }
        return payload;
    }

    function int16(bytes as ByteArray, offset as Number) as Number {
        return bytes.decodeNumber(Lang.NUMBER_FORMAT_SINT16, {
            :offset => offset,
            :endianness => Lang.ENDIAN_BIG,
        }) as Number;
    }

    function int32(bytes as ByteArray, offset as Number) as Number {
        return bytes.decodeNumber(Lang.NUMBER_FORMAT_SINT32, {
            :offset => offset,
            :endianness => Lang.ENDIAN_BIG,
        }) as Number;
    }

    //! VESC's own 4-byte float encoding (`buffer_get_float32_auto`), not IEEE 754.
    function float32Auto(bytes as ByteArray, offset as Number) as Double {
        var raw = bytes.decodeNumber(Lang.NUMBER_FORMAT_UINT32, {
            :offset => offset,
            :endianness => Lang.ENDIAN_BIG,
        }) as Number or Long;
        var value = raw.toLong();
        var exponent = ((value >> 23) & 0xFF).toNumber();
        var significand = (value & 0x7FFFFF).toDouble();
        if (exponent == 0 && significand == 0.0d) {
            return 0.0d;
        }
        var result = (significand / (8388608.0d * 2.0d) + 0.5d) * (Math.pow(2.0d, exponent - 126) as Double);
        return ((value >> 31) & 1) != 0 ? -result : result;
    }
}
