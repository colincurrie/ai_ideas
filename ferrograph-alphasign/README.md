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
  effects/modes, fonts, positions, speeds, dots pictures/memory
  configuration. No I/O beyond the serial write.
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
| GET | `/files` | everything the sign is holding, by type: `{text: {...}, strings: {...}, dots: {...}} `|
| GET | `/messages` | just the text files (server-tracked, not read back from the sign - see "Known limitations") |
| POST | `/messages` | `{label, position, mode, speed, priority, runs, dry_run}` - write/update a text file. `dry_run: true` returns the hex bytes without opening the port |
| DELETE | `/messages/:label` | blank that label (`?dry_run=true` supported) |
| POST | `/strings` | `{label, text, dry_run}` - write/update a string file |
| DELETE | `/strings/:label` | empty that string |
| POST | `/image` | `{label, width, height, pixels, monochrome, force, dry_run}` - store a dots picture (see "Images" below) |
| DELETE | `/image/:label` | drop that picture from the layout |
| POST | `/priority` | same shape as `/messages`, targets the Priority Text File |
| DELETE | `/priority` | clear the priority override |
| POST | `/raw` | `{command_code, data, type, address, dry_run}` - escape hatch for anything not wrapped above |

### The three file types

This is the single most important thing to understand about the sign, and
getting it wrong is what makes a display mysteriously go blank:

- **Text files** are the only files the sign *displays*. They take part in
  its run sequence.
- **String files** and **dots picture files** are inert on their own.
  Writing one just stores it in memory. It reaches the display solely
  because a text file *calls* it inline, at a specific point in its
  content.

So `runs` on `/messages` is a list of pieces, each one of:

```json
{"text": "SALE", "color": "red", "font": "large_standard"}
{"type": "string", "label": "1"}
{"type": "image",  "label": "P"}
```

`position`/`mode`/`speed` apply to the whole message (that's a protocol
constraint, not an API limitation - see `docs/xdf-firmware-notes.md`);
`color`/`font` are per-run, letting you highlight parts of a message
differently.

File labels are one shared namespace across all three types - a memory
configuration lists each label once, with a type - so the same label can't
be both a text file and a picture. The API rejects that with a 400 rather
than sending the sign a contradictory layout.

### Memory configuration (and why the display sometimes blanks)

Defining memory replaces the sign's **entire** file layout and erases every
file's contents, which makes it something to send as rarely as possible.
`serial_api` tracks the layout it wants (`serial_api/layout.rb`) and:

1. **Doesn't configure memory at all for text-only use.** XDF's power-on
   default already provides a text file per label, so a text-only setup
   never needs one - and never blanks.
2. **Re-sends every file's contents immediately after any configuration**,
   since they were just erased. This is what stops sending a picture from
   wiping the message that displays it.
3. **Rounds file sizes up to 256-byte buckets**, so ordinary edits stay
   inside the reservation already made for them instead of forcing a
   reconfiguration on every small change.

Responses say which happened: `reconfigured: true/false`, plus
`memory_config_bytes_hex` when one was sent. Adding the first string or
picture, or changing the set of files, does require one; editing contents
afterwards does not. Rewriting a **string** never does - strings are double
buffered, which makes them the right home for anything that changes often.

### Images

`pixels` is a flat string of `width * height` characters, row-major, each
one of `0` (off), `1` (red), `2` (green), `3` (yellow) - see
`AlphaSign::DotsColors`. The sign's hardware isn't built to sustain more
than 50% of its LED chips lit at once (yellow counts as two - it's
red+green together); `/image` computes this and refuses to send with a
422 unless `force: true` is passed.

`POST /image` only *stores* the picture. To actually show it, send a
message whose `runs` include `{"type": "image", "label": "P"}`.

The dots picture and memory configuration wire formats are reconstructed
from a third-party source rather than the official Alpha manual - see
`docs/xdf-firmware-notes.md`, "Dots Picture files and Memory
Configuration", and test with a small image first.

## web_app

The authenticated UI. Needs a few more environment variables. Either
`export` them each time:

```
export SESSION_SECRET=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')
export WEB_APP_PASSWORD_HASH=$(bin/hash_password)   # prompts for a password, prints its bcrypt hash
export WEB_APP_USERNAME=admin                        # default
export SERIAL_API_URL=http://127.0.0.1:4568           # default
export WEB_APP_SECURE_COOKIES=false                   # only for local http:// testing - leave true once behind HTTPS
bundle exec rackup web_app/config.ru -o 127.0.0.1 -p 4567
```

...or for local development, copy `.env.example` to `.env` and fill it in
once - both services load it automatically (via the `dotenv` gem) from the
repo root, regardless of which directory you start them from. **Wrap
`WEB_APP_PASSWORD_HASH` in single quotes in `.env`** - bcrypt hashes are
full of `$` characters, which `dotenv` will otherwise try to interpolate
as shell-style variable references and silently mangle. See the comments
in `.env.example` for the full list of variables (it covers `serial_api`
too - one `.env` at the repo root serves both).

Either way, a real exported environment variable (e.g. a systemd
`EnvironmentFile` in production, see `DEPLOY.md`) always takes priority
over `.env` - `dotenv` only fills in what isn't already set.

Single shared login (one username/password for now - see "Known
limitations" for what multi-user would take). Visit `http://127.0.0.1:4567`,
sign in, and use the compose page: pick a label, type a message, select
text and apply a color/font from the toolbar to highlight parts of it,
choose position/effect/speed, then Preview (see the bytes without
sending) or Send.

The **Insert image** and **Insert string** buttons drop a reference chip
into the message at the cursor. That chip is what makes a stored picture or
string actually appear on the display (see "The three file types" above) -
it's a call, not a copy, so re-saving the string or picture behind it
updates what's shown without touching the message.

The **Strings** card writes reusable text a message can call. Rewriting a
string swaps its contents in without blanking the display or disturbing the
message around it, which makes it the right place for anything that changes
often.

The Image card maps whatever you upload to the sign's red/green/yellow
palette entirely in your browser (HTML canvas) - `serial_api` never sees
raw image bytes, only the final pixel grid. It shows a live preview and the
estimated LED load percentage before you send anything, and blocks (with a
clear "send anyway" override) if that load exceeds the sign's 50% safety
limit.

Images are never scaled **up**: anything that already fits the 135x16
display is used at its exact pixel size, so a 16x16 icon stays a 16x16
icon rather than being blown up to fill the panel (which can only invent
detail that isn't there, smearing whole LEDs across what were crisp edges).
Only oversized artwork is scaled down, preserving aspect ratio. Both size
fields stay editable if you want something else.

Two colour-mapping modes, and the choice matters a lot:

- **Dither** (Floyd-Steinberg error diffusion) - for photos and gradients,
  where mixing adjacent pixels approximates tones the sign can't display
  directly.
- **Solid** (straight nearest-colour) - for text and logos. Dithering
  high-contrast graphics turns crisp letterforms into unreadable speckle,
  so anything word-shaped wants this instead.

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

- **`GET /files` reflects what this server has sent, not the sign's
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
- **Image support is web_app only** - the CLI (`bin/alphasign`) can't send
  images. It would need a real Ruby image-decoding dependency (the web app
  avoids one entirely by doing resize/dither in the browser); happy to add
  if wanted.
- **Dots Picture/Memory Configuration protocol is lower-confidence than
  the rest of this library** - reconstructed from a third-party source
  rather than the official Alpha manual (which wasn't reachable to verify
  directly). See `docs/xdf-firmware-notes.md`'s "Dots Picture files and
  Memory Configuration" section for specifics; test with a small image
  before trusting it for anything that matters.
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
