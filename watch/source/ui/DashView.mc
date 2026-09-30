import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

enum Page {
    PAGE_MAIN,
    PAGE_SPEED,
    PAGE_BATTERY,
    PAGE_POWER,
    PAGE_RIDE,
    PAGE_COUNT
}

//! A labelled value on a data page.
typedef Cell as [String, String];

//! Garmin-style data pages, switched with UP/DOWN. Every page but the big-speed one uses the same
//! three-band layout: one field on top, one or two across the middle, two at the bottom. While the
//! board is not live, the middle label says why and the values are greyed.
class DashView extends WatchUi.View {
    var page as Page = PAGE_MAIN;

    private var _board as Board;

    function initialize(board as Board) {
        View.initialize();
        _board = board;
    }

    function onUpdate(dc as Dc) as Void {
        var status = _board.status(System.getTimer());
        var refloat = _board.session.refloat;
        var bms = _board.session.bms;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (page == PAGE_SPEED) {
            drawSpeedPage(dc, status, refloat);
        } else if (page == PAGE_BATTERY) {
            var hasBms = bms != null;
            // Without a BMS the controller's own pack voltage and battery current stand in.
            var packV = bms != null ? bms.packVoltage : (refloat != null ? refloat.batteryVoltage : null);
            var packA = bms != null ? bms.current : (refloat != null ? refloat.batteryCurrent : null);
            drawBands(dc, status,
                [Format.batteryLabel(bms), Format.battery(refloat, bms)],
                [
                    ["PACK V", Format.volts(packV)],
                    [hasBms ? "BMS A" : "BATT A", Format.amps(packA)],
                ],
                [
                    ["CELL MIN", cell(bms != null ? bms.cellMin : null)],
                    ["CELL MAX", cell(bms != null ? bms.cellMax : null)],
                ],
                hasBms ? null : "NO BMS");
        } else if (page == PAGE_POWER) {
            drawBands(dc, status,
                ["BATT A", Format.amps(refloat != null ? refloat.batteryCurrent : null)],
                [["MOTOR A", Format.amps(refloat != null ? refloat.motorCurrent : null)]],
                [
                    ["CTL C", Format.whole(refloat != null ? refloat.mosfetTemp : null)],
                    ["MOT C", Format.whole(refloat != null ? refloat.motorTemp : null)],
                ],
                null);
        } else if (page == PAGE_RIDE) {
            drawBands(dc, status,
                ["STATE", refloat != null ? refloat.stateName() : Format.NONE],
                [
                    ["PITCH", Format.signed(refloat != null ? refloat.pitch : null)],
                    ["ROLL", Format.signed(refloat != null ? refloat.roll : null)],
                ],
                [
                    ["FOOTPADS", footpads(refloat)],
                    ["TRIP " + Format.distanceUnit(), Format.distance(_board.session.tripMeters())],
                ],
                null);
        } else {
            drawBands(dc, status,
                [Format.batteryLabel(bms), Format.battery(refloat, bms)],
                [[Format.speedUnit(), Format.speed(refloat)]],
                [
                    ["DUTY", Format.duty(refloat)],
                    ["CTL / MOT", Format.whole(refloat != null ? refloat.mosfetTemp : null) + "/" + Format.whole(refloat != null ? refloat.motorTemp : null)],
                ],
                null);
        }
        drawPageDots(dc);
        if (_board.tilt != Vesc.TILT_CENTER) {
            var percent = tiltPercent(_board.tilt);
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(dc.getWidth() / 2, dc.getHeight() * 4 / 100, Graphics.FONT_XTINY, "TILT " + (percent > 0 ? "+" : "") + percent + "%", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    //! Speed alone, as large as the font allows, with duty as a bar underneath.
    private function drawSpeedPage(dc as Dc, status as String?, refloat as RefloatSample?) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var color = status == null ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 20 / 100, Graphics.FONT_XTINY, status != null ? status : Format.speedUnit(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 47 / 100, Graphics.FONT_NUMBER_THAI_HOT, Format.speed(refloat), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var duty = refloat != null ? refloat.duty.abs() : 0.0;
        var barW = w * 60 / 100;
        var barH = 10;
        var x = (w - barW) / 2;
        var y = h * 74 / 100;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, y, barW, barH);
        dc.setColor(dutyColor(duty), Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, y, (barW * (duty > 1.0 ? 1.0 : duty)).toNumber(), barH);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, y + barH + 14, Graphics.FONT_XTINY, "DUTY " + Format.duty(refloat), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Top band, middle band (1-2 cells), bottom band (2 cells). `middleNote` replaces the middle
    //! label, e.g. to say a page has no source for its data.
    private function drawBands(dc as Dc, status as String?, top as Cell, middle as Array<Cell>, bottom as Array<Cell>, middleNote as String?) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var live = status == null;
        var color = live ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY;
        var topY = h * 32 / 100;
        var bottomY = h * 68 / 100;

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(0, topY, w, topY);
        dc.drawLine(0, bottomY, w, bottomY);
        dc.drawLine(cx, bottomY, cx, h);
        if (middle.size() > 1) {
            dc.drawLine(cx, topY, cx, bottomY);
        }

        drawCell(dc, cx, h * 12 / 100, topY - 4, top, Graphics.FONT_NUMBER_MILD, color);
        if (middle.size() == 1) {
            var label = status != null ? status : (middleNote != null ? middleNote : middle[0][0]);
            drawCell(dc, cx, topY + 14, bottomY - 6, [label, middle[0][1]], Graphics.FONT_NUMBER_HOT, color);
        } else {
            drawCell(dc, cx / 2 + 8, topY + 14, bottomY - 6, [middle[0][0], middle[0][1]], Graphics.FONT_NUMBER_MEDIUM, color);
            drawCell(dc, cx + cx / 2 - 8, topY + 14, bottomY - 6, [middle[1][0], middle[1][1]], Graphics.FONT_NUMBER_MEDIUM, color);
            var note = status != null ? status : middleNote;
            if (note != null) {
                dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, bottomY - 12, Graphics.FONT_XTINY, note, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        }
        drawCell(dc, cx / 2 + 12, bottomY + 14, h * 88 / 100, bottom[0], Graphics.FONT_NUMBER_MILD, color);
        drawCell(dc, cx + cx / 2 - 12, bottomY + 14, h * 88 / 100, bottom[1], Graphics.FONT_NUMBER_MILD, color);
    }

    //! Label near the top of its slot, value centred in what is left. Text that is not a number
    //! (a state name) falls back to a text font, since number fonts carry digits only.
    private function drawCell(dc as Dc, x as Number, labelY as Number, bottomY as Number, cell as Cell, font as Graphics.FontType, color as Graphics.ColorType) as Void {
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, labelY, Graphics.FONT_XTINY, cell[0], Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var valueTop = labelY + dc.getFontHeight(Graphics.FONT_XTINY) / 2;
        var text = cell[1];
        var valueFont = isNumeric(text) ? font : Graphics.FONT_SMALL;
        dc.drawText(x, (valueTop + bottomY) / 2, valueFont, text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Which page is showing, as dots along the left edge.
    private function drawPageDots(dc as Dc) as Void {
        var h = dc.getHeight();
        var spacing = 9;
        var y0 = h / 2 - (PAGE_COUNT - 1) * spacing / 2;
        for (var i = 0; i < PAGE_COUNT; i++) {
            dc.setColor(i == page ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(7, y0 + i * spacing, i == page ? 3 : 2);
        }
    }

    private function isNumeric(text as String) as Boolean {
        var chars = text.toCharArray();
        for (var i = 0; i < chars.size(); i++) {
            if ("0123456789.-+%/".find(chars[i].toString()) == null) {
                return false;
            }
        }
        return true;
    }

    private function cell(volts as Float?) as String {
        return volts == null ? Format.NONE : (volts as Float).format("%.2f");
    }

    private function footpads(refloat as RefloatSample?) as String {
        if (refloat == null) {
            return Format.NONE;
        }
        var pads = refloat.footpads();
        return pads == 2 ? "BOTH" : (pads == 1 ? "HALF" : "OFF");
    }

    private function dutyColor(duty as Float) as Graphics.ColorType {
        if (duty >= 0.85) {
            return Graphics.COLOR_RED;
        }
        return duty >= 0.7 ? Graphics.COLOR_YELLOW : Graphics.COLOR_GREEN;
    }
}

class DashDelegate extends WatchUi.BehaviorDelegate {
    private var _board as Board;
    private var _controls as BoardControls;
    private var _view as DashView;

    function initialize(board as Board, controls as BoardControls, view as DashView) {
        BehaviorDelegate.initialize();
        _board = board;
        _controls = controls;
        _view = view;
    }

    //! START: the board picker until a board is connected, then the menu (tunes, lights, tilt).
    function onSelect() as Boolean {
        if (_board.link.state == LINK_SCANNING && _board.link.preferredName == null) {
            WatchUi.pushView(new BoardPicker(_board), new BoardPickerDelegate(_board), WatchUi.SLIDE_UP);
        } else {
            WatchUi.pushView(new MainMenu(_controls), new MainMenuDelegate(_board, _controls), WatchUi.SLIDE_UP);
        }
        return true;
    }

    function onNextPage() as Boolean {
        _view.page = ((_view.page + 1) % PAGE_COUNT) as Page;
        WatchUi.requestUpdate();
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.page = ((_view.page + PAGE_COUNT - 1) % PAGE_COUNT) as Page;
        WatchUi.requestUpdate();
        return true;
    }
}
