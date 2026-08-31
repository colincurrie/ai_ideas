# ferrograph-alphasign

A command-line tool for sending messages to Alpha-protocol LED signs — such
as a **Ferrograph Aurora 63 running XDF firmware** — over a serial link,
using the AMS/Adaptive Micro Systems **Alpha Sign Communications Protocol**.

This is step one of a larger goal: a full configuration app for the sign.
The CLI here is deliberately small and the protocol logic lives in a plain
Ruby library (`lib/alpha_sign`) so it can be reused by a GUI, a web app, or
anything else later.

## Hardware

- **Sign**: Ferrograph 63 display, XDF firmware (implements the Alpha
  protocol over RS232/RS422).
- **Adapter**: DriverGenius SerialGuardX USB-C-to-RS232 (DB9) FTDI adapter.

Plug the adapter in and connect it to the sign's RS232 port with a
straight-through (not null-modem) serial cable unless the sign's manual says
otherwise.

### Finding the serial device path

- **Linux**: `ls /dev/ttyUSB*` (run `dmesg | tail` after plugging in if
  nothing shows up).
- **macOS**: `ls /dev/tty.usbserial-*`
- **Windows**: check Device Manager → Ports (COM & LPT) for the assigned
  `COMx` port.

## Install

Requires Ruby (tested on 3.x) and the `serialport` gem, which has a native
extension:

```
bundle install
```

If `serialport` fails to build:
- **Linux**: install build tools first, e.g. `sudo apt install build-essential ruby-dev`.
- **macOS**: install Xcode Command Line Tools: `xcode-select --install`.
- **Windows**: use RubyInstaller with the DevKit option, or run this from WSL.

You don't need the gem installed to explore the CLI — `--dry-run` and the
`list-*` commands work without it.

## Usage

```
bin/alphasign send [options] MESSAGE
bin/alphasign clear [options]
bin/alphasign raw [options] COMMAND_CODE [DATA]
bin/alphasign list-modes
bin/alphasign list-colors
bin/alphasign list-positions
```

Examples:

```
# Send a plain message (default: hold, middle line)
bin/alphasign send --device /dev/ttyUSB0 "Hello, world!"

# Rotating red text at speed 3
bin/alphasign send -d /dev/ttyUSB0 -m rotate -c red -s 3 "Sale ends Friday"

# Full 24-bit color, if the sign supports RGB pixels
bin/alphasign send -d /dev/ttyUSB0 -c FF8800 "Custom color"

# See the exact bytes that would be sent, without opening the serial port
bin/alphasign send -d /dev/ttyUSB0 --dry-run "test message"

# Blank the sign
bin/alphasign clear -d /dev/ttyUSB0
```

Run `bin/alphasign send --help` for the full list of options (label,
position, mode, speed, color, priority, serial parameters, sign
address/type).

### Serial parameters

Defaults are **9600 baud, 8 data bits, no parity, 1 stop bit** — the
standard default for Alpha-protocol signs. Override with `--baud`,
`--data-bits`, `--parity`, and `--stop-bits` if your sign has been
configured differently (check the sign's own setup menu/DIP switches).

### Sign address / type

By default, packets use type code `Z` (all sign types) and address `00`
(broadcast) — the standard way to talk to a single sign on a point-to-point
link without knowing its configured address. Override with `--type` and
`--address` if you've set up multiple signs on a shared line.

## Running tests

```
bundle exec rake test
```

The tests only exercise the pure protocol/packet-building logic (no serial
hardware needed), so they also run fine without `bundle install` /
`serialport`, e.g. per-file with:

```
ruby -Ilib -Itest test/alpha_sign/packet_test.rb
```

## Protocol references

- [Alpha® Sign Communications Protocol (Alpha-American, PDF)](https://www.alpha-american.com/alpha-manuals/M-Protocol.pdf)
- [msparks/alphasign](https://github.com/msparks/alphasign) — a Python
  implementation of the same protocol, used to cross-check the constants in
  this library.

Only a subset of the protocol is wrapped so far: WRITE_TEXT (`send`/`clear`)
and a `raw` escape hatch for anything else (special functions, string/dots
files, read-back commands, etc.) — useful groundwork for the configuration
app planned next.
