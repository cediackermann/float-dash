import Toybox.Activity;
import Toybox.Application;
import Toybox.Application.Properties;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Float Dash as a data field, for riding inside a native Garmin activity — typically one following
//! a course, so navigation stays Garmin's own. Shows speed, duty and battery in whatever slot it is
//! given: side by side in a wide half-screen slot, stacked in a tall one, one line in a small one.
class FloatFieldApp extends Application.AppBase {
    var board as Board;

    function initialize() {
        AppBase.initialize();
        // A data field cannot show a picker: it pairs with the device named in its settings, or the
        // first one advertising the VESC Bluetooth service.
        board = new Board(true, Properties.getValue("boardName") as String?);
    }

    function onStart(state as Dictionary?) as Void {
        board.start();
    }

    function onStop(state as Dictionary?) as Void {
        board.stop();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new FloatField(board)];
    }
}

class FloatField extends WatchUi.DataField {
    private var _board as Board;

    function initialize(board as Board) {
        DataField.initialize();
        _board = board;
    }

    //! Called about once a second by the activity. Data fields get no timers, so this is where an
    //! unanswered request times out; replies drive the request rate themselves.
    function compute(info as Activity.Info) as Void {
        _board.pump();
    }

    function onUpdate(dc as Dc) as Void {
        var background = getBackgroundColor();
        var foreground = background == Graphics.COLOR_BLACK ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        dc.setColor(foreground, background);
        dc.clear();

        var status = _board.status(System.getTimer());
        var refloat = _board.session.refloat;
        var bms = _board.session.bms;
        var color = status == null ? foreground : Graphics.COLOR_DK_GRAY;
        var cells = [
            [status != null ? status : Format.speedUnit(), Format.speed(refloat)],
            ["DUTY", Format.duty(refloat)],
            [Format.batteryLabel(bms), Format.battery(refloat, bms)],
        ] as Array<[String, String]>;

        var w = dc.getWidth();
        var h = dc.getHeight();
        if (h < 50) {
            // Too small for labels: one line, speed first.
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2, Graphics.FONT_SMALL, cells[0][1] + "  " + cells[1][1] + "  " + cells[2][1], Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else if (w >= h * 3 / 2) {
            // Wide slot (e.g. half the screen): speed on the left, duty and battery stacked right.
            // Round screens clip the corners of edge slots, so keep off the sides.
            var inset = w / 10;
            var split = w * 55 / 100;
            drawCell(dc, (inset + split) / 2, 0, h, cells[0], Graphics.FONT_NUMBER_MEDIUM, color, foreground);
            drawCell(dc, (split + w - inset) / 2, 0, h / 2, cells[1], Graphics.FONT_SMALL, color, foreground);
            drawCell(dc, (split + w - inset) / 2, h / 2, h, cells[2], Graphics.FONT_SMALL, color, foreground);
        } else {
            // Tall or square slot: speed on top, duty and battery side by side below.
            var split = h * 58 / 100;
            drawCell(dc, w / 2, 0, split, cells[0], Graphics.FONT_NUMBER_MEDIUM, color, foreground);
            drawCell(dc, w / 3, split, h, cells[1], Graphics.FONT_SMALL, color, foreground);
            drawCell(dc, w * 2 / 3, split, h, cells[2], Graphics.FONT_SMALL, color, foreground);
        }
    }

    //! Label above, value below, both centred in the band `[top, bottom)`.
    private function drawCell(dc as Dc, x as Number, top as Number, bottom as Number, cell as [String, String], font as Graphics.FontType, color as Graphics.ColorType, labelColor as Graphics.ColorType) as Void {
        var labelHeight = dc.getFontHeight(Graphics.FONT_XTINY);
        var valueHeight = dc.getFontHeight(font);
        var y = top + (bottom - top - labelHeight - valueHeight) / 2;
        dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_XTINY, cell[0], Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y + labelHeight, font, cell[1], Graphics.TEXT_JUSTIFY_CENTER);
    }
}
