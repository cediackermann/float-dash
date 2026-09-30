import Toybox.Application;
import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

//! Backstop for request timeouts and repaints; replies drive the request rate themselves.
const TICK_MS = 250;
//! Repaint at least this often so a board that went quiet turns stale on screen.
const REPAINT_TICKS = 4;

class FloatDashApp extends Application.AppBase {
    var board as Board;
    var controls as BoardControls;

    private var _timer as Timer.Timer = new Timer.Timer();
    private var _ticks as Number = 0;

    function initialize() {
        AppBase.initialize();
        // Only after AppBase is up: the board reads settings and storage. The watch app lets the
        // rider pick the board, so it never pairs on its own.
        board = new Board(false, null);
        controls = new BoardControls(board);
    }

    function onStart(state as Dictionary?) as Void {
        board.start();
        _timer.start(method(:onTick), TICK_MS, true);
    }

    function onStop(state as Dictionary?) as Void {
        _timer.stop();
        board.stop();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new DashView(board);
        return [view, new DashDelegate(board, controls, view)];
    }

    function onTick() as Void {
        board.pump();
        _ticks += 1;
        if (_ticks % REPAINT_TICKS == 0) {
            WatchUi.requestUpdate();
        }
    }
}
