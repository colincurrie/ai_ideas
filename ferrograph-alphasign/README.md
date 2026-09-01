# ferrograph-alphasign

Control a **Ferrograph Aurora 63 display running XDF firmware** over a
serial link, using the Adaptive Microsystems/AMS **Alpha Sign
Communications Protocol** (which XDF implements, per its own user guide,
"fully compatible with the Adaptive Microsystems Alpha 1.0 protocol, with
some Alpha 2.0 enhancements supported").

Three pieces, all sharing one protocol library:

```
                          ┌────────────────────┐
 bin/alphasign  ──────────►                    │
 (CLI, direct to the sign)│   lib/alpha_sign    │  Alpha protocol: packets,
                          │  (protocol library) │  colors, effects, fonts,
 serial_api  ─────────────►                    │  positions, speeds
 (HTTP wrapper around it) └────────────────────┘

[Browser] --HTTPS, login+session--> [web_app] --localhost HTTP, no auth--> [serial_api] --RS232--> [Sign]
                                    (public/tunnel-facing)     (both run on the Pi)   (127.0.0.1 only)
```

- **`lib/alpha_sign`** - the protocol itself: packet framing, colors,
  effects/modes, fonts, positions, speeds. No I/O beyond the serial write.
- **`bin/alphasign`** - a CLI for sending messages directly, useful for
  testing and one-off use without running any servers.
- **`serial_api/`** - a small Sinatra service that owns the serial port
  and exposes it as JSON HTTP. No authentication of its own - meant to
  stay bound to `127.0.0.1`.
- **`web_app/`** - the authenticated front door: login, session, the
  compose UI, and a proxy through to `serial_api`. This is the only piece
  meant to be reachable over the network (e.g. via Tailscale).

The protocol constants in the library (colors, effects, positions, fonts)
are transcribed directly from the XDF Extended Display Firmware User Guide
(v4.26), *not* the generic Alpha protocol - XDF repurposes a few Alpha byte
codes for different effects and adds a large number of its own extensions.
See `docs/xdf-firmware-notes.md` for a fuller summary of what's in that
manual and how it maps onto this code.

## Hardware

- **Sign**: Ferrograph Aurora 63 display (135 pixels wide, 2-colour
  red/green matrix), XDF firmware.
- **Adapter**: DriverGenius SerialGuardX USB-C-to-RS232 (DB9) FTDI adapter.
- **Server**: a Raspberry Pi, physically connected to the sign, running
  both `serial_api` and `web_app` (see `DEPLOY.md`).

Plug the adapter in and connect it to the sign's RS232 port (the display
has an RJ45 connector with a non-standard pinout - see the
`aurora_info.doc` hardware document for the correct wiring to a 9-way
D-type connector).

### Finding the serial device path

- **Linux**: `ls /dev/ttyUSB*` (run `dmesg | tail` after plugging in if
  nothing shows up).
- **macOS**: `ls /dev/tty.usbserial-*`
- **Windows**: check Device Manager → Ports (COM & LPT) for the assigned
  `COMx` port.

## Install

Requires Ruby (tested on 3.x). `bundle install` pulls in everything -
`serialport` (has a native extension) for talking to the actual port, plus
Sinatra/Puma for the two services:

```
bundle install
```

If `serialport` fails to build:
- **Linux**: install build tools first, e.g. `sudo apt install build-essential ruby-dev libudev-dev`.
- **macOS**: install Xcode Command Line Tools: `xcode-select --install`.
- **Windows**: use RubyInstaller with the DevKit option, or run this from WSL.

You don't need the gem installed to explore the CLI or run either service
in dry-run mode - `--dry-run`/`dry_run: true` and the `list-*`
commands/`/options` endpoint work without it, and a real send fails with a
clean error (not a crash) if the gem or device isn't there.

## The CLI (`bin/alphasign`)

For quick testing or direct one-off use, without running any servers:

```
bin/alphasign send [options] MESSAGE
bin/alphasign clear [options]
bin/alphasign raw [options] COMMAND_CODE [DATA]
bin/alphasign list-modes
bin/alphasign list-colors
bin/alphasign list-positions
bin/alphasign list-fonts
```

Examples:

```
# Send a plain message (default: hold, middle line)
bin/alphasign send --device /dev/ttyUSB0 "Hello, world!"

# Rotating red text at speed 3
bin/alphasign send -d /dev/ttyUSB0 -m rotate -c red -s 3 "Sale ends Friday"

# One of XDF's many extended effects, in a rainbow colour
bin/alphasign send -d /dev/ttyUSB0 -m twinkle -c rainbow1 "Big news!"

# A large font (the CLI applies one font/color for the whole message; the
# web app's compose UI supports mixing multiple per selection)
bin/alphasign send -d /dev/ttyUSB0 -f large_standard "BIG TEXT"

# See the exact bytes that would be sent, without opening the serial port
bin/alphasign send -d /dev/ttyUSB0 --dry-run "test message"

# Blank the sign
bin/alphasign clear -d /dev/ttyUSB0
```

Run `bin/alphasign send --help` for the full list of options (label,
position, mode, speed, color, font, priority, serial parameters, sign
address/type).

## serial_api

The device driver service. Configuration is via environment variables
(`SERIAL_DEVICE`, `SERIAL_BAUD`, etc. - see `serial_api/config.rb` for the
full list and defaults). Run it directly for local testing:

```
bundle exec rackup serial_api/config.ru -o 127.0.0.1 -p 4568
```

Endpoints (all JSON):

| Method | Path | Purpose |
|---|---|---|
| GET | `/status` | connection health: device, baud, address/type, last error |
| GET | `/options` | valid modes/colors/positions/fonts, for populating a UI |
| GET | `/messages` | labels sent since this process started (server-tracked, not read back from the sign - see "Known limitations") |
| POST | `/messages` | `{label, position, mode, speed, priority, runs, dry_run}` - write/update a text file. `runs` is `[{text, color, font}, ...]`; `dry_run: true` returns the hex bytes without opening the port |
| DELETE | `/messages/:label` | blank that label (`?dry_run=true` supported) |
| POST | `/priority` | same shape as `/messages`, targets the Priority Text File (label `0`) |
| DELETE | `/priority` | clear the priority override |
| POST | `/raw` | `{command_code, data, type, address, dry_run}` - escape hatch for anything not wrapped above |

`position`/`mode`/`speed` apply to the whole message (that's a protocol
constraint, not an API limitation - see `docs/xdf-firmware-notes.md`);
`color`/`font` are per-run, letting you highlight parts of a message
differently.

## web_app

The authenticated UI. Needs a few more environment variables:

```
export SESSION_SECRET=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')
export WEB_APP_PASSWORD_HASH=$(bin/hash_password)   # prompts for a password, prints its bcrypt hash
export WEB_APP_USERNAME=admin                        # default
export SERIAL_API_URL=http://127.0.0.1:4568           # default
export WEB_APP_SECURE_COOKIES=false                   # only for local http:// testing - leave true once behind HTTPS
bundle exec rackup web_app/config.ru -o 127.0.0.1 -p 4567
```

Single shared login (one username/password for now - see "Known
limitations" for what multi-user would take). Visit `http://127.0.0.1:4567`,
sign in, and use the compose page: pick a label, type a message, select
text and apply a color/font from the toolbar to highlight parts of it,
choose position/effect/speed, then Preview (see the bytes without
sending) or Send.

For actually deploying this on a Raspberry Pi wired to the sign, with
systemd units and Tailscale for remote access, see **`DEPLOY.md`**.

## Running tests

```
bundle exec rake test
```

Covers `lib/alpha_sign`, `serial_api`, and `web_app` - all pure
request-level tests (`Rack::Test` against the Sinatra apps directly, with
`serial_api`'s tests using `dry_run` and `web_app`'s using a stub client
in place of a real `serial_api`), so none of it needs real hardware or a
running server. Also runs fine without `bundle install`/`serialport` for
just the library tests, e.g.:

```
ruby -Ilib -Itest test/alpha_sign/packet_test.rb
```

## Known limitations / roadmap

- **`GET /messages` reflects what this server has sent, not the sign's
  actual state** - there's no read-back sync. XDF does support reading a
  Text file's current content/status back (see
  `docs/xdf-firmware-notes.md`, "Serial readback"); worth adding if
  server restarts or multiple clients start making the difference matter.
- **No checksum on outgoing packets.** Valid, simpler protocol form, but
  means a corrupted send isn't caught by the sign - see
  `docs/xdf-firmware-notes.md`, "Checksum processing" for what's at stake.
- **Single shared login.** Fine for personal/family use; would need a real
  user table (and probably per-user audit logging of who sent what) to
  become multi-account.
- Not yet wrapped in the API, though the protocol supports all of them
  (see `docs/xdf-firmware-notes.md`): run-time/day scheduling (show a
  message only during certain hours/days), the Timeout Message (a
  fallback shown if the sign stops hearing from this app), beeper and
  aux-port/IO control, and live time/date display codes. All reachable
  today via the `raw` command/endpoint in the meantime.

## Protocol references

- Ferrograph/XDF's own *Extended Display Firmware User Guide* (v4.26) —
  supplied by the display owner; the source for the hardware-specific
  details throughout this repo. See `docs/xdf-firmware-notes.md` for a
  working summary.
- [Alpha® Sign Communications Protocol (Alpha-American, PDF)](https://www.alpha-american.com/alpha-manuals/M-Protocol.pdf) —
  the base protocol XDF builds on (packet framing, command codes).
- [msparks/alphasign](https://github.com/msparks/alphasign) — a Python
  implementation of the generic protocol, used as an initial cross-check
  before the XDF-specific manual was available.
