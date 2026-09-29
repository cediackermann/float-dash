import Toybox.Lang;

//! Rebuilds VESC packets from Bluetooth notifications. A notification carries at most one MTU of
//! bytes, so one packet may span several, and bytes before a valid start are skipped. Returns only
//! payloads whose CRC checks out.
class Reassembler {
    private var _buffer as ByteArray = []b;

    function initialize() {
    }

    function reset() as Void {
        _buffer = []b;
    }

    function feed(chunk as ByteArray) as Array<ByteArray> {
        _buffer.addAll(chunk);
        var packets = [] as Array<ByteArray>;
        while (_buffer.size() > 0) {
            var total = frameAt(0);
            if (total > 0) {
                var headerLength = _buffer[0] == 0x02 ? 2 : 3;
                packets.add(_buffer.slice(headerLength, total - 3));
                drop(total);
            } else if (total < 0) {
                drop(1);
            } else {
                // Incomplete. A corrupted byte can look like a start with a long length and would
                // hold the buffer forever; a complete frame further on proves it is not a real one.
                var next = nextCompleteFrame();
                if (next < 0) {
                    break;
                }
                drop(next);
            }
        }
        return packets;
    }

    //! The frame's total length if a valid frame starts at `start`, 0 if it may still complete,
    //! -1 if it cannot be one.
    private function frameAt(start as Number) as Number {
        var size = _buffer.size() - start;
        var first = _buffer[start];
        if (first != 0x02 && first != 0x03) {
            return -1;
        }
        var headerLength = first == 0x02 ? 2 : 3;
        if (size < headerLength) {
            return 0;
        }
        var length = first == 0x02 ? _buffer[start + 1] : (_buffer[start + 1] << 8) | _buffer[start + 2];
        var total = headerLength + length + 3;
        if (size < total) {
            return 0;
        }
        if (_buffer[start + total - 1] != 0x03) {
            return -1;
        }
        var crcAt = start + headerLength + length;
        var crc = (_buffer[crcAt] << 8) | _buffer[crcAt + 1];
        return Vesc.crc16(_buffer, start + headerLength, crcAt) == crc ? total : -1;
    }

    private function nextCompleteFrame() as Number {
        for (var i = 1; i < _buffer.size(); i++) {
            if (frameAt(i) > 0) {
                return i;
            }
        }
        return -1;
    }

    private function drop(count as Number) as Void {
        _buffer = count >= _buffer.size() ? []b : _buffer.slice(count, null);
    }
}
