import Toybox.Lang;

//! One Refloat `GET_ALLDATA` sample (mode 2). Layout: Refloat `cmd_send_all_data()`, as documented
//! and tested in Vescape (`docs/refloatAlldata.md`).
class RefloatSample {
    //! km/h, signed (negative is riding backwards).
    var speed as Float = 0.0;
    //! -1..1.
    var duty as Float = 0.0;
    var batteryVoltage as Float = 0.0;
    var motorCurrent as Float = 0.0;
    var batteryCurrent as Float = 0.0;
    var pitch as Float = 0.0;
    var roll as Float = 0.0;
    //! Lower nibble: Refloat `state_compat` (1 RUNNING, 2 TILTBACK, 3 WHEELSLIP, ...).
    var state as Number = 0;
    var switchState as Number = 0;
    //! Metres, or null before mode 2.
    var odometer as Double? = null;
    var mosfetTemp as Float? = null;
    var motorTemp as Float? = null;

    function initialize() {
    }

    //! Riding, including stopped on the nose: Refloat's own engaged states.
    function isEngaged() as Boolean {
        var s = state & 0x0F;
        return s == 1 || s == 2 || s == 3;
    }

    //! Refloat `state_compat` (lower nibble), as VESC Tool names it.
    function stateName() as String {
        var names = [
            "STARTUP", "RUNNING", "TILTBACK", "WHEELSLIP", "UPSIDE DOWN", "FLYWHEEL",
            "PITCH FAULT", "ROLL FAULT", "HALF FOOTPAD", "NO FOOTPAD", "?", "STARTUP FAULT",
            "REVERSE STOP", "QUICKSTOP", "CHARGING", "DISABLED",
        ];
        return names[state & 0x0F];
    }

    //! 0 no footpad, 1 one half, 2 both: Refloat's switch_compat (lower 3 bits).
    function footpads() as Number {
        return switchState & 0x07;
    }
}

//! Pack-level values from a VESC BMS (`COMM_BMS_GET_VALUES`). Only what the dashboard shows.
class BmsSample {
    var packVoltage as Float = 0.0;
    var current as Float = 0.0;
    var cellMin as Float? = null;
    var cellMax as Float? = null;
    //! 0..1, or null when the firmware variant does not send it.
    var soc as Float? = null;
    //! The controller's CAN id as configured on the BMS, when sent.
    var controllerId as Number? = null;

    function initialize() {
    }
}

module Decoders {
    //! Returns a sample, the fault code (Number) when Refloat reports a fault, or null when the
    //! payload is not an ALLDATA reply.
    function refloatAllData(payload as ByteArray) as RefloatSample or Number or Null {
        if (payload.size() < 5 ||
                payload[0] != Vesc.COMM_CUSTOM_APP_DATA ||
                payload[1] != Vesc.REFLOAT_MAGIC ||
                payload[2] != Vesc.REFLOAT_GET_ALLDATA) {
            return null;
        }
        var mode = payload[3];
        if (mode == Vesc.REFLOAT_FAULT_MODE) {
            return payload[4];
        }
        if (payload.size() < 34) {
            return null;
        }
        var sample = new RefloatSample();
        sample.roll = Vesc.int16(payload, 8) / 10.0;
        sample.state = payload[10];
        sample.switchState = payload[11];
        sample.pitch = Vesc.int16(payload, 20) / 10.0;
        sample.batteryVoltage = Vesc.int16(payload, 23) / 10.0;
        sample.speed = Vesc.int16(payload, 27) / 10.0 * 3.6;
        sample.motorCurrent = Vesc.int16(payload, 29) / 10.0;
        sample.batteryCurrent = Vesc.int16(payload, 31) / 10.0;
        // Duty rides as (x - 128) / 100; the +-1 step is quantisation noise at standstill.
        var duty = payload[33] - 128;
        sample.duty = (duty >= -1 && duty <= 1) ? 0.0 : duty / 100.0;
        if (mode >= 2 && payload.size() >= 42) {
            sample.odometer = Vesc.float32Auto(payload, 35);
            sample.mosfetTemp = payload[39] / 2.0;
            sample.motorTemp = payload[40] / 2.0;
        }
        return sample;
    }

    //! Scaled big-endian integers, not floats: float32 fields are int32 / scale, float16 fields
    //! int16 / scale. Layout: `vesc_bms_fw` `commands.c`, `COMM_BMS_GET_VALUES`:
    //!   v_tot, v_charge, i_in, i_in_ic (f32 1e6) · ah_cnt, wh_cnt (f32 1e3) · cell_num (u8) ·
    //!   v_cell[] (f16 1e3) · bal_state[] (u8) · temp_num (u8) · temps[] (f16 1e2) ·
    //!   temp_ic, temp_hum, hum, temp_max_cell (f16 1e2) · soc, soh (f16 1e3) · controller_id (u8)
    //! SoC sits past a variable-length temperature block, so it is read only when every length before
    //! it is plausible.
    function bmsValues(payload as ByteArray) as BmsSample? {
        if (payload.size() < 26 || payload[0] != Vesc.COMM_BMS_GET_VALUES) {
            return null;
        }
        var sample = new BmsSample();
        sample.packVoltage = (Vesc.int32(payload, 1) / 1.0e6).toFloat();
        sample.current = (Vesc.int32(payload, 9) / 1.0e6).toFloat();
        var index = 25;
        var cells = payload[index];
        index += 1;
        if (cells < 1 || cells > 60 || payload.size() < index + cells * 2) {
            return null;
        }
        for (var i = 0; i < cells; i++) {
            var cell = Vesc.int16(payload, index) / 1000.0;
            index += 2;
            if (sample.cellMin == null || cell < (sample.cellMin as Float)) {
                sample.cellMin = cell;
            }
            if (sample.cellMax == null || cell > (sample.cellMax as Float)) {
                sample.cellMax = cell;
            }
        }
        // Balancing flags, one per cell.
        index += cells;
        if (payload.size() <= index) {
            return sample;
        }
        var temps = payload[index];
        index += 1;
        if (temps > 30) {
            return sample;
        }
        index += temps * 2 + 8;
        if (payload.size() >= index + 2) {
            var soc = Vesc.int16(payload, index) / 1000.0;
            // A pack is never outside 0..100 %; anything else is a layout this decoder does not know.
            if (soc >= 0.0 && soc <= 1.0) {
                sample.soc = soc;
            }
        }
        // Past SoC and SoH.
        index += 4;
        if (payload.size() > index) {
            sample.controllerId = payload[index];
        }
        return sample;
    }

    //! `[COMM_PING_CAN, id, id, ...]` -> the ids that answered, or null for anything else.
    function pingCan(payload as ByteArray) as Array<Number>? {
        if (payload.size() < 1 || payload[0] != Vesc.COMM_PING_CAN) {
            return null;
        }
        var ids = [] as Array<Number>;
        for (var i = 1; i < payload.size(); i++) {
            ids.add(payload[i]);
        }
        return ids;
    }
}
