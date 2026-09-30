import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

//! START on the data pages: everything the rider can do to the board.
class MainMenu extends WatchUi.Menu2 {
    function initialize(controls as BoardControls) {
        Menu2.initialize({ :title => "Float Dash" });
        addItem(new WatchUi.MenuItem("Tunes", "Save and apply", :tunes, {}));
        var lights = controls.lights;
        addItem(new WatchUi.ToggleMenuItem("Lights", lights == null ? "State unknown" : null, :leds,
            lights != null && (lights & Vesc.LIGHT_LEDS) != 0, {}));
        addItem(new WatchUi.ToggleMenuItem("Headlight", lights == null ? "State unknown" : null, :headlights,
            lights != null && (lights & Vesc.LIGHT_HEADLIGHTS) != 0, {}));
        addItem(new WatchUi.MenuItem("Remote tilt", null, :tilt, {}));
        addItem(new WatchUi.MenuItem("Switch board", null, :board, {}));
    }
}

class MainMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _board as Board;
    private var _controls as BoardControls;

    function initialize(board as Board, controls as BoardControls) {
        Menu2InputDelegate.initialize();
        _board = board;
        _controls = controls;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :tunes) {
            WatchUi.pushView(new TunesMenu(_controls), new TunesMenuDelegate(_controls), WatchUi.SLIDE_LEFT);
        } else if (id == :leds || id == :headlights) {
            var on = (item as WatchUi.ToggleMenuItem).isEnabled();
            _controls.setLight(id == :leds ? Vesc.LIGHT_LEDS : Vesc.LIGHT_HEADLIGHTS, on);
        } else if (id == :tilt) {
            WatchUi.pushView(new TiltView(_board), new TiltDelegate(_board), WatchUi.SLIDE_LEFT);
        } else if (id == :board) {
            WatchUi.pushView(new BoardPicker(_board), new BoardPickerDelegate(_board), WatchUi.SLIDE_LEFT);
        }
    }
}

//! The four tune slots. Refreshed whenever it comes back on screen, e.g. after a save.
class TunesMenu extends WatchUi.Menu2 {
    private var _controls as BoardControls;

    function initialize(controls as BoardControls) {
        Menu2.initialize({ :title => "Tunes" });
        _controls = controls;
        for (var slot = 0; slot < TUNE_SLOTS; slot++) {
            addItem(new WatchUi.MenuItem("", null, slot, {}));
        }
        refresh();
    }

    function onShow() as Void {
        refresh();
        Menu2.onShow();
    }

    private function refresh() as Void {
        for (var slot = 0; slot < TUNE_SLOTS; slot++) {
            var item = getItem(slot) as WatchUi.MenuItem;
            var tune = _controls.tune(slot);
            item.setLabel(tune == null ? "Empty " + (slot + 1) : tune.name);
            item.setSubLabel(tune == null ? "Save board tune here" : "Refloat " + tune.version);
        }
    }
}

class TunesMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _controls as BoardControls;

    function initialize(controls as BoardControls) {
        Menu2InputDelegate.initialize();
        _controls = controls;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var slot = item.getId() as Number;
        var tune = _controls.tune(slot);
        if (tune == null) {
            askName(_controls, slot, "Tune " + (slot + 1), :save);
        } else {
            WatchUi.pushView(new TuneActionsMenu(tune), new TuneActionsDelegate(_controls, slot), WatchUi.SLIDE_LEFT);
        }
    }
}

class TuneActionsMenu extends WatchUi.Menu2 {
    function initialize(tune as Tune) {
        Menu2.initialize({ :title => tune.name });
        addItem(new WatchUi.MenuItem("Apply", "Board stopped, feet off", :apply, {}));
        addItem(new WatchUi.MenuItem("Replace", "With the board's tune now", :replace, {}));
        addItem(new WatchUi.MenuItem("Rename", null, :rename, {}));
        addItem(new WatchUi.MenuItem("Delete", null, :delete, {}));
    }
}

class TuneActionsDelegate extends WatchUi.Menu2InputDelegate {
    private var _controls as BoardControls;
    private var _slot as Number;

    function initialize(controls as BoardControls, slot as Number) {
        Menu2InputDelegate.initialize();
        _controls = controls;
        _slot = slot;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        var tune = _controls.tune(_slot) as Tune;
        if (id == :apply) {
            WatchUi.pushView(
                new WatchUi.Confirmation("Apply " + tune.name + "? Replaces the whole Refloat config, lights and battery settings too."),
                new TuneConfirmDelegate(_controls, _slot),
                WatchUi.SLIDE_IMMEDIATE);
        } else if (id == :replace) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            _controls.saveTune(_slot, tune.name);
            showStatusLater(_controls);
        } else if (id == :rename) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            askName(_controls, _slot, tune.name, :rename);
        } else if (id == :delete) {
            _controls.delete(_slot);
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        }
    }
}

class TuneConfirmDelegate extends WatchUi.ConfirmationDelegate {
    private var _controls as BoardControls;
    private var _slot as Number;

    function initialize(controls as BoardControls, slot as Number) {
        ConfirmationDelegate.initialize();
        _controls = controls;
        _slot = slot;
    }

    function onResponse(response as WatchUi.Confirm) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            _controls.applyTune(_slot);
            showStatusLater(_controls);
        }
        return true;
    }
}

//! Asks for a tune name, then saves (`:save`) or renames (`:rename`).
function askName(controls as BoardControls, slot as Number, initial as String, action as Symbol) as Void {
    WatchUi.pushView(new WatchUi.TextPicker(initial), new TuneNameDelegate(controls, slot, action), WatchUi.SLIDE_LEFT);
}

class TuneNameDelegate extends WatchUi.TextPickerDelegate {
    private var _controls as BoardControls;
    private var _slot as Number;
    private var _action as Symbol;

    function initialize(controls as BoardControls, slot as Number, action as Symbol) {
        TextPickerDelegate.initialize();
        _controls = controls;
        _slot = slot;
        _action = action;
    }

    function onTextEntered(text as String, changed as Boolean) as Boolean {
        var name = text.length() > 0 ? text : "Tune " + (_slot + 1);
        if (_action == :rename) {
            _controls.rename(_slot, name);
        } else {
            _controls.saveTune(_slot, name);
            showStatusLater(_controls);
        }
        return true;
    }
}

//! Pushes the tune status screen once the picker or confirmation that started the action has
//! closed itself; pushing from inside their callbacks would be popped along with them.
var statusTimer as Timer.Timer? = null;

function showStatusLater(controls as BoardControls) as Void {
    statusTimer = new Timer.Timer();
    (statusTimer as Timer.Timer).start(new StatusPusher(controls).method(:push), 100, false);
}

class StatusPusher {
    private var _controls as BoardControls;

    function initialize(controls as BoardControls) {
        _controls = controls;
    }

    function push() as Void {
        WatchUi.pushView(new TuneStatusView(_controls), new WatchUi.BehaviorDelegate(), WatchUi.SLIDE_UP);
    }
}

//! How the last tune action is going; BACK leaves it (the action carries on).
class TuneStatusView extends WatchUi.View {
    private var _controls as BoardControls;

    function initialize(controls as BoardControls) {
        View.initialize();
        _controls = controls;
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth();
        var h = dc.getHeight();
        var text = _controls.tuneStatus;
        var area = new WatchUi.TextArea({
            :text => text != null ? text : "",
            :color => Graphics.COLOR_WHITE,
            :font => [Graphics.FONT_SMALL, Graphics.FONT_TINY, Graphics.FONT_XTINY],
            :justification => Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER,
            :locX => w / 8,
            :locY => h / 5,
            :width => w * 3 / 4,
            :height => h * 3 / 5,
        });
        area.draw(dc);
        if (!_controls.isBusy()) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 86 / 100, Graphics.FONT_XTINY, "BACK", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }
}

//! Remote tilt: UP and DOWN step the held input, START returns it to neutral. The tilt stays while
//! the app runs (leaving this screen keeps it) and ends when the app closes or the link drops.
class TiltView extends WatchUi.View {
    private var _board as Board;

    function initialize(board as Board) {
        View.initialize();
        _board = board;
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        var w = dc.getWidth();
        var h = dc.getHeight();
        var percent = tiltPercent(_board.tilt);
        var live = _board.session.phase == PHASE_POLLING;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 18 / 100, Graphics.FONT_XTINY, live ? "REMOTE TILT" : "NOT CONNECTED", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(percent == 0 ? Graphics.COLOR_WHITE : Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 45 / 100, Graphics.FONT_NUMBER_HOT, (percent > 0 ? "+" : "") + percent + "%", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 70 / 100, Graphics.FONT_XTINY, "UP / DOWN: change", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(w / 2, h * 79 / 100, Graphics.FONT_XTINY, "START: back to 0", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}

//! Input as a percentage of full scale either way, 0 at neutral.
function tiltPercent(tilt as Number) as Number {
    return ((tilt - Vesc.TILT_CENTER) * 100.0 / 127.0).toNumber();
}

//! One step of remote tilt, about 10 % of full scale.
const TILT_STEP = 13;

class TiltDelegate extends WatchUi.BehaviorDelegate {
    private var _board as Board;

    function initialize(board as Board) {
        BehaviorDelegate.initialize();
        _board = board;
    }

    function onPreviousPage() as Boolean {
        step(TILT_STEP);
        return true;
    }

    function onNextPage() as Boolean {
        step(-TILT_STEP);
        return true;
    }

    function onSelect() as Boolean {
        _board.setTilt(Vesc.TILT_CENTER);
        WatchUi.requestUpdate();
        return true;
    }

    private function step(delta as Number) as Void {
        if (_board.session.phase != PHASE_POLLING) {
            return;
        }
        var next = _board.tilt + delta;
        // Land exactly on neutral when a step crosses it, so START is not the only way back.
        if ((_board.tilt < Vesc.TILT_CENTER && next > Vesc.TILT_CENTER) || (_board.tilt > Vesc.TILT_CENTER && next < Vesc.TILT_CENTER)) {
            next = Vesc.TILT_CENTER;
        }
        _board.setTilt(next);
        WatchUi.requestUpdate();
    }
}
