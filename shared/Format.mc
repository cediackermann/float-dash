import Toybox.Lang;
import Toybox.System;

//! Display formatting shared by the watch app and the data field. Units follow the watch's own
//! distance setting, like Garmin's native fields.
module Format {
    const NONE = "--";

    function metric() as Boolean {
        return System.getDeviceSettings().distanceUnits != System.UNIT_STATUTE;
    }

    function speedUnit() as String {
        return metric() ? "KM/H" : "MPH";
    }

    //! Board speed, riding direction dropped.
    function speed(sample as RefloatSample?) as String {
        if (sample == null) {
            return NONE;
        }
        var kmh = sample.speed.abs();
        return (metric() ? kmh : kmh * 0.621371).format("%.0f");
    }

    function duty(sample as RefloatSample?) as String {
        return sample == null ? NONE : percent(sample.duty.abs() * 100.0);
    }

    //! The BMS state of charge when it sends one, else pack voltage from the controller.
    function battery(sample as RefloatSample?, bms as BmsSample?) as String {
        if (bms != null && bms.soc != null) {
            return percent((bms.soc as Float) * 100.0);
        }
        return sample == null ? NONE : volts(sample.batteryVoltage);
    }

    function batteryLabel(bms as BmsSample?) as String {
        return (bms != null && bms.soc != null) ? "BATTERY" : "PACK V";
    }

    function distance(meters as Double?) as String {
        if (meters == null) {
            return NONE;
        }
        var km = (meters as Double) / 1000.0;
        return (metric() ? km : km * 0.621371).format("%.1f");
    }

    function distanceUnit() as String {
        return metric() ? "KM" : "MI";
    }

    function whole(value as Float?) as String {
        return value == null ? NONE : (value as Float).format("%.0f");
    }

    function percent(value as Float?) as String {
        return value == null ? NONE : (value as Float).format("%.0f") + "%";
    }

    function volts(value as Float?) as String {
        return value == null ? NONE : (value as Float).format("%.1f");
    }

    function amps(value as Float?) as String {
        return value == null ? NONE : (value as Float).format("%.0f");
    }

    function signed(value as Float?) as String {
        return value == null ? NONE : (value as Float).format("%+.1f");
    }
}
