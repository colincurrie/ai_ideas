# ferrograph-alphasign

A command-line tool for sending messages to a **Ferrograph Aurora 63
display running XDF firmware** over a serial link, using the
Adaptive Microsystems/AMS **Alpha Sign Communications Protocol** (which XDF
implements, per its own user guide, "fully compatible with the Adaptive
Microsystems Alpha 1.0 protocol, with some Alpha 2.0 enhancements
supported").

This is step one of a larger goal: a full configuration app for the sign.
The CLI here is deliberately small and the protocol logic lives in a plain
Ruby library (`lib/alpha_sign`) so it can be reused by a GUI, a web app, or
anything else later.

The protocol constants in this library (colors, effects, positions) are
transcribed directly from the XDF Extended Display Firmware User Guide
(v4.26), *not* the generic Alpha protocol — XDF repurposes a few Alpha byte
codes for different effects and adds a large number of its own extensions,
documented below.

## Hardware

- **Sign**: Ferrograph Aurora 63 display (135 pixels wide, 2-colour
  red/green matrix), XDF firmware.
- **Adapter**: DriverGenius SerialGuardX USB-C-to-RS232 (DB9) FTDI adapter.

Plug the adapter in and connect it to the sign's RS232 port (the display has
an RJ45 connector with a non-standard pinout — see the `aurora_info.doc`
hardware document for the correct wiring to a 9-way D-type connector).

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

# One of XDF's many extended effects, in a rainbow colour
bin/alphasign send -d /dev/ttyUSB0 -m twinkle -c rainbow1 "Big news!"

# See the exact bytes that would be sent, without opening the serial port
bin/alphasign send -d /dev/ttyUSB0 --dry-run "test message"

# Blank the sign
bin/alphasign clear -d /dev/ttyUSB0
```

Run `bin/alphasign send --help` for the full list of options (label,
position, mode, speed, color, priority, serial parameters, sign
address/type).

### Serial parameters

XDF **always** operates with 8 data bits, no parity, 1 stop bit — per the
manual, "the 7,e,2 mode available on ADF and Alpha 4000 displays is not
available with XDF". The CLI defaults match this (`--parity none
--data-bits 8 --stop-bits 1`); only change these if you're targeting
different, non-XDF Alpha hardware.

Baud rate is set by the sign's own DIP switches 5 and 6, and depends on the
control board fitted:

| Switch 6 | Switch 5 | Fast board (FDS-101 v4.01) | Slow board (FDS-CB2 / v4.0) |
|----------|----------|-----------------------------|------------------------------|
| Off      | Off      | 38400                       | 19200                        |
| Off      | On       | 19200                       | 9600                         |
| On       | Off      | 9600                        | 4800                         |
| On       | On       | 4800                        | 2400                         |

Setting both DIP switches 7 and 8 on shows the XDF status/splash screen,
which displays the currently configured address and baud rate. The CLI
defaults to `--baud 9600`; pass `--baud` to match whatever the sign is
actually set to.

### Sign address / type

By default, packets use type code `Z` (all sign types) and address `00`
(broadcast) — the standard way to talk to a single sign on a point-to-point
link without knowing its configured address (also XDF's recommended setup
for a single display: "setting network address 00H ... is the most
sensible"). Two more specific type codes are available via `--type` if you
ever need them: `A` restricts to XDF/ADF signs only (useful if genuine Alpha
signs share the network), and `a` is the Alpha 4120C-equivalent code
specific to the Aurora 63. Override `--address` if you've set up multiple
signs on a shared RS422 line, each with a unique non-zero address.

### Colors, effects and positions

`list-colors`, `list-modes`, and `list-positions` enumerate everything this
CLI knows how to name. A few things worth knowing, straight from the XDF
manual:

- The Aurora 63 is a 2-colour (red/green) matrix, so several named colors
  are visually identical on this hardware — `dim_red`/`dim_green` show as
  plain red/green, and `brown`/`orange`/`yellow` all show as yellow. They're
  still distinct protocol codes, kept for compatibility with software/data
  written for genuine Alpha signs.
- There's no RGB/hex color support — that's an RGB-pixel-sign feature (e.g.
  Betabrite Prism) this hardware doesn't have.
- The Alpha 3.0 `left`/`right` positions aren't supported by XDF ("not
  supported ... and never will be"), so only `top`, `bottom`, `middle`, and
  `fill` are offered.
- Most modes in `list-modes` are XDF's *extended* effects (fades, colour
  splits, cover/reveal, drop-down, etc.) — well beyond the basic Alpha
  effect set, and not available on genuine Alpha hardware.

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

- Ferrograph/XDF's own *Extended Display Firmware User Guide* (v4.26) —
  supplied by the display owner; the source for the hardware-specific
  details above (serial format, DIP switch table, colors, effects,
  device type codes).
- [Alpha® Sign Communications Protocol (Alpha-American, PDF)](https://www.alpha-american.com/alpha-manuals/M-Protocol.pdf) —
  the base protocol XDF builds on (packet framing, command codes).
- [msparks/alphasign](https://github.com/msparks/alphasign) — a Python
  implementation of the generic protocol, used as an initial cross-check
  before the XDF-specific manual was available.

Only a subset of the protocol is wrapped so far: WRITE_TEXT (`send`/`clear`)
and a `raw` escape hatch for anything else (special functions, string/dots
files, read-back commands, run-time scheduling, beeper/IO control, etc. —
see Appendices A and B of the XDF manual for the full command set) — useful
groundwork for the configuration app planned next.
