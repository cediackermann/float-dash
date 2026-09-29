import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.WatchUi;

//! Lists what the scan found — any VESC node: controller, Bluetooth bridge or BMS. Picking one pairs
//! it. "Forget board" drops the pairing and where the controller was, and starts scanning again.
class BoardPicker extends WatchUi.Menu2 {
    function initialize(board as Board) {
        Menu2.initialize({ :title => "Pick board" });
        var found = board.link.found;
        for (var i = 0; i < found.size(); i++) {
            var name = found[i].getDeviceName();
            var nus = board.link.advertisesNus(found[i]);
            addItem(new WatchUi.MenuItem(
                name != null ? name : "Unnamed",
                nus ? "VESC UART" : "RSSI " + found[i].getRssi(),
                i,
                {}
            ));
        }
        addItem(new WatchUi.MenuItem("Forget board", "Scan again", :forget, {}));
    }
}

class BoardPickerDelegate extends WatchUi.Menu2InputDelegate {
    private var _board as Board;

    function initialize(board as Board) {
        Menu2InputDelegate.initialize();
        _board = board;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :forget) {
            _board.forget();
        } else if (id instanceof Number && id < _board.link.found.size()) {
            _board.link.pair(_board.link.found[id]);
        }
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}
