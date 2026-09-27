# extron_trace_multilogger

Live multi-processor trace logging for Extron ControlScript (Python) systems. A Python TraceServer runs inside the program and streams per-room debug trace over telnet (TCP 6000). A PowerShell multilogger connects to many processors at once and writes each to its own timestamped log file.

## Why

CSDU can only hold one trace session at a time. Each processor's trace server is an independent TCP listener, so the multilogger bypasses CSDU entirely and captures every processor concurrently - to files you can grep, diff, or hand to someone else.

```
  processor-01 :6000 --+
  processor-02 :6000 --+--> trace_multilogger.ps1 --> logs\processor-01\Trace_MultiLogger_<time>.log
  processor-03 :6000 --+                              logs\processor-02\...
                                                      logs\processor-03\...
```

## Repo layout

| Path | What it is |
|---|---|
| `trace_server/trace_server.py` | `TraceServer` class - drop into your ControlScript project. |
| `multilogger/trace_multilogger.ps1` | The multi-processor logger (one background job per processor). |
| `multilogger/run-trace_multilogger.bat` | Double-click launcher for the script. |

## 1. Add the trace server to your program

Copy `trace_server.py` into your project's `src/` folder and wire it up:

```python
from extronlib.device import ProcessorDevice
from extronlib.interface import EthernetServerInterfaceEx
from trace_server import TraceServer

processor = ProcessorDevice('processor-01')
all_rooms = []

trace_listener = EthernetServerInterfaceEx(6000, 'TCP')
trace = TraceServer(trace_listener, processor, all_rooms)

class Room:
    def __init__(self, name, trace):
        self.name = name
        self.trace = trace
        self.trace_enabled = False    # per-room relay flag, toggled over telnet
        all_rooms.append(self)

    def __str__(self):
        return 'device status here'   # returned by "<room>:Devices"

boardroom = Room('Boardroom', trace)
boardroom.trace.trace_message(boardroom.name, 'Display 1: Power On')
```

A room only needs to expose `name` and `trace_enabled`, and call `trace.trace_message(name, msg)` wherever it wants output. Messages from a room are relayed only while that room's `trace_enabled` is `True`; messages from `'System'` (command replies) always go out. Every message is also `print()`ed to the CSDU console.

### Telnet commands

Connect to `<processor ip>:6000` with any telnet client:

| Command | Effect |
|---|---|
| `Help` | List commands |
| `Room Names` | List rooms known to the trace server |
| `<room>:True` / `<room>:False` | Turn a room's trace on / off |
| `<room>:Status` / `All:Status` | Show trace state for one room / every room |
| `<room>:Devices` | Print the room object (`__str__`) |
| `ClearAll` | Turn trace off for every room |

Output looks like:

```
2026-01-01 12:00:00.123456
Boardroom | Display 1: Power On
```

## 2. Configure and run the multilogger

Edit the `$Processors` table near the top of `multilogger/trace_multilogger.ps1` - one entry per processor:

```powershell
@{ Name = 'processor-01'; IP = '192.0.2.11'; Rooms = @('Boardroom','Training','Huddle1','Huddle2') }
```

The shipped entries are demo data (`192.0.2.x` is the RFC 5737 documentation range and won't answer) - replace them with your own. `Rooms` must match the room names your program registers with the trace server.

Then double-click `multilogger/run-trace_multilogger.bat` (or run the script directly). A tick-box dialog lets you choose which processors to log; all are ticked by default. On connect, each worker sends `<room>:True` for every room in its list, so there is nothing to type by hand.

The window must stay open - each connection is a PowerShell background job and closing the window stops them all. From that same window:

```powershell
Get-Job                                     # job status per processor
Receive-Job -Name processor-02 -Keep        # peek at recent output without stopping
Get-Job | Stop-Job; Get-Job | Remove-Job    # stop everything
```

Logs land in `logs\<processor name>\Trace_MultiLogger_<yyyy-MM-dd_HH-mm>.log` (gitignored). Use `-LogRoot <path>` to write them elsewhere, and `-Port` if your trace server doesn't use 6000.

## Caveats

- **Only `trace_message()` output is captured.** Plain `print()` statements go to the CSDU console over CSDU's own connection and are not streamed to the trace server.
- **Trace isn't turned off on disconnect.** Nothing sends `ClearAll` when the multilogger stops, so `trace_enabled` stays `True` (and rooms keep mirroring to the CSDU console) until you send `ClearAll` or `<room>:False` yourself.
- **Connection handshake takes ~5-6 s.** Workers wait 7 s after connecting before sending commands, then re-send `<room>:True` every 30 s for any room that hasn't confirmed.
- **Unreachable processors are retried every 10 s** and logged as `UNREACHABLE`; a dropped connection reconnects automatically.

## Requirements

- Windows PowerShell 5.1 or later on Windows (the processor picker uses WinForms).
- An Extron processor running a ControlScript program with `TraceServer` wired in, reachable on its trace port.

## License

GPL-3.0 - see [LICENSE](LICENSE).
