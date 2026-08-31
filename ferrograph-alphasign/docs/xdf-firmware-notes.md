# XDF firmware notes

A working summary of the parts of Ferrograph's *Extended Display Firmware
User Guide* (XDF, v4.26, for Aurora series displays) that matter for
controlling the sign over serial - i.e. what this repo's code is built
against. It is **not** a copy of the manual and isn't exhaustive; it exists
so the reasoning behind `lib/alpha_sign` doesn't have to be re-derived from
scratch later. Page/section references are to the original document
(supplied by the display owner, not included in this repo).

Scope: this covers protocol framing, addressing, text/effects/colors, and
the operational details needed to send messages reliably. It does **not**
cover hardware installation, temperature/photocell calibration, brightness
tuning, or the AlphaNET/Kitchi integration appendices (sections 3.31-3.35,
Appendices E-I of the source manual) - those matter for physically setting
up or recalibrating the display, not for the message-sending API this repo
implements, and can be summarized later if the app grows into that territory.

## What XDF is

XDF is third-party firmware (by the same author as the earlier ADF
firmware) that replaces a Ferrograph Aurora display's stock firmware,
adding capacity and features while staying protocol-compatible with
Adaptive Microsystems (AMS)/Alpha signs: "fully compatible with the
Adaptive Microsystems Alpha 1.0 protocol, with some Alpha 2.0 enhancements
supported." Our Aurora 63 uses the `XDFRM63C.HEX`/`XDFRM63D.HEX` variant
(135 pixels wide, 2-colour red/green matrix), protocol-equivalent to an
Alpha 4120C.

## Packet framing

```
<NUL x5> <SOH> <type code> <address> <STX> <command code><data...> <EOT>
```

- `NUL` (0x00) x5: wake-up padding so the sign's UART can sync on a new
  packet (standard Alpha requirement, not XDF-specific).
- `SOH` (0x01): start of header. XDF also supports the Alpha "2 byte"
  (`]`/0x5D-prefixed) and "3 byte" (`_`/0x5F-prefixed) framing variants and
  will auto-detect which one is in use from the SOH byte, but this repo
  only implements the plain 1-byte format - it's the simplest, is what
  most tooling uses, and the others exist mainly for links that can't pass
  full 8-bit/control-character data cleanly.
- Type code + address: see "Addressing" below.
- `STX` (0x02): start of text, precedes the command code.
- Command code: single ASCII letter selecting the operation - `A` =
  Write Text, `E` = Write Special Function, `G` = Write String, etc. (full
  list in `AlphaSign::Protocol` and Appendix B of the source manual).
- `EOT` (0x04): end of transmission.
- Checksum: the protocol supports an optional trailing checksum
  (`ETX` + 4 hex digits + `EOT` instead of a bare `EOT`). XDF validates it
  when present and flags a Serial Error Status bit on mismatch. **Not
  implemented here** - the unchecksummed form is valid protocol and
  simpler; worth adding later if link reliability ever becomes an issue
  (see "Checksum processing" below for what's at stake).

Multiple messages can be nested in one transmission (repeat
`SOH`...`EOT` segments back to back); not used by this repo, which sends
one packet per request.

## Serial settings

- **Always 8 data bits, no parity, 1 stop bit.** Unlike genuine ADF/Alpha
  4000 hardware, XDF has no 7E2 mode - "only two DIP switches are available
  for comms options, and both are required for baud rate settings." This
  is why `serial_api`'s defaults are fixed at 8/none/1.
- Baud rate is set by the sign's own DIP switches 5+6, and depends on
  which control board is fitted:

  | Switch 6 | Switch 5 | Fast board (FDS-101 v4.01) | Slow board (FDS-CB2 / v4.0) |
  |----------|----------|-----------------------------|------------------------------|
  | Off      | Off      | 38400                       | 19200                        |
  | Off      | On       | 19200                       | 9600                         |
  | On       | Off      | 9600                        | 4800                         |
  | On       | On       | 4800                        | 2400                         |

- DIP switches 7+8 both on shows the XDF status/splash screen (firmware
  variant, address, baud rate, RAM fitted) - useful for confirming what
  the sign is actually configured for without a PC.
- XDF masks the top bit of every received byte (i.e. only processes
  0x00-0x7F), so it tolerates 7-bit-only senders even though it always
  runs 8N1 itself.

## Addressing

- Switches 1-4 set the sign's own address, 0x00-0x0F. `0x00` is the
  broadcast address - "XDF will interpret messages sent to any address,
  even if non-zero" when the sign's own address is 0. Fine, and
  recommended, for a single sign on RS232; must be avoided (each sign
  needs a unique non-zero address) on a shared RS422 network, since
  broadcast read-requests can make multiple signs answer at once and
  collide.
- Type code (which sign *model* a packet is addressed to) - `AlphaSign::Protocol`
  defaults to `Z` (all types). Two more specific codes exist:
  - `A` (0x41): XDF/ADF-specific, added so a packet can be restricted to
    only XDF/ADF signs on a network that also has genuine Alpha hardware.
  - Per-model codes matching genuine Alpha part numbers, so existing Alpha
    software addresses XDF signs correctly: Aurora 62 = `t` (Alpha 4080C),
    Aurora 63 = `a` (Alpha 4120C), Aurora 64 = `b` (Alpha 4160C).
  - `?` and `!` also mean "all types" (the latter restricted to signs
    with visual verification configured).

## Serial readback

XDF supports the Alpha read-back conventions (Read Text/String/Dots,
Read Memory Configuration, Read Serial Error Status, etc.) on both RS232
and RS422, auto-selecting whichever port it last received on. Responses
always use `0` for both device type and address in the header, and always
include a checksum, regardless of how the request arrived. **Not used by
this repo** - `serial_api` tracks "what we've sent" in memory rather than
reading the sign's actual state back (see the root README's note on this
under "Known limitations"). If that's ever built, look at:
- Special Function `0x22` (Read General Information) and `0x25` (Dump
  Memory, the only nested/multi-packet response XDF sends) for whole-sign
  state.
- Special Function `0x24` (Read Memory Configuration) for per-file status.
- Reading Text file label `0` returns the Priority Text File instead of a
  normal file.
- Unsupported read requests get a response with a literal
  `*** NOT SUPPORTED ***` body rather than being silently dropped, except
  the Network Query command (`0x2D`), which XDF ignores outright (it needs
  timing behavior XDF's buffered serial can't guarantee).

## Serial buffer protection / practical sending advice

- No flow control exists in the Alpha protocol; XDF protects itself by
  throttling (freezing) the display once its receive buffer is >66% full,
  and un-freezing once it drains to empty. Under normal single-message
  traffic from this app this is a non-issue.
- Responses use a small (256 byte) transmit buffer; a large read-back
  response (Dump Memory, a big Text file) can stall the sign's processing
  of *new* incoming messages while it's still sending the old response.
  Relevant only if/when read-back is implemented - don't fire off more
  writes while waiting on a large read.

## Checksum processing

Not implemented in this repo (see "Packet framing" above), but worth
knowing the failure mode if it's ever added: XDF can't fully buffer huge
messages before validating a checksum, so a corrupted **Text File Update
in Full Blank/single-buffered mode** (the default) still wipes the
existing message even though the new one is rejected - i.e. a bad
checksum can still blank the display. String/Dots files and Text files in
Brief Blank/Transparent mode are double-buffered and don't have this
problem. This is really an argument *for* adding checksums eventually
(so corrupted sends are caught before they reach the sign at all, rather
than relying on this fallback behavior), not a reason to avoid them.

## Text files and multi-run formatting

A `WRITE_TEXT` packet's payload is:

```
<command "A"> <file label> <ESC> <position code> <effect code> <message text...>
```

- **Position and effect are set once, at the start of the file** - not
  per-run. This is why `AlphaSign::Runs` (which builds multi-color/font
  messages) only touches color and font, never position/mode - the
  protocol has no way to change those mid-message.
- **Color (`0x1C` + code) and font/character-set (`0x1A` + code) are
  per-character attributes** that persist on the sign until the next
  color/font code appears (or the file restarts). `AlphaSign::Runs` only
  emits a new code when a run's color/font actually differs from the
  previous run's, matching that persistence rather than re-emitting a code
  before every run.
- Position codes: `0x20` middle, `0x22` top, `0x26` bottom, `0x30` fill.
  Alpha 3.0's `left`/`right` codes are explicitly **not** supported by XDF
  ("not supported by XDF, and never will be") and aren't offered by this
  library.
- Speed/pause codes (`0x15`-`0x19` for speed 1-5, `0x09` for "no hold") are
  also file-wide, applied once near the start like position/effect -
  `serial_api` prepends the speed code (when given) before the encoded
  runs, same idea.
- Label `0` is reserved for the Priority Text File (see below) - it isn't
  a real file-system slot, so `AlphaSign::TextFile.new(..., priority:
  true)` always targets label `"0"` regardless of the `label:` passed.

### Character sets (fonts)

Selected via `0x1A` + code. XDF's default is `3` (7-high standard).
`AlphaSign::CharSets` exposes 7 practically-distinct fonts; the manual
also documents 3 more codes (`7`, `9`, `A`) that render identically to
`4`, `6`, `8` respectively on this hardware (Alpha-compatibility aliases,
not distinct fonts on Aurora units) - reachable via the `raw`
command/API if ever needed, but omitted from the named list to avoid
confusing near-duplicates.

### Colors

Selected via `0x1C` + code, ~45 documented on XDF (`AlphaSign::Colors`
has the full set) vs. the dozen or so on genuine Alpha signs - XDF adds
many stripe/rainbow/auto-color variants. Because the Aurora 63 only has
red/green LEDs, several codes are visually identical here even though
they're distinct protocol values (kept for round-tripping content
authored for real Alpha signs): dim red/dim green render as plain
red/green, and brown/orange/yellow (and amber) all render as yellow (amber
= yellow, exactly like on 2-line Alpha hardware). There's no RGB/hex
color support - that's an RGB-pixel-sign feature (e.g. Betabrite Prism)
this hardware doesn't have.

XDF's colour-shift-flashing attribute cycles Red→Yellow→Green→Red as an
alternative to flashing on/off - not implemented in this app yet (see
"Not yet implemented" below).

### Effects (display modes)

Two tiers, both single ASCII/short codes right after the position code:

- **Basic effects** (Appendix C) - one character, `a`-`x`. Byte values
  mostly match genuine Alpha codes, but XDF repurposes several for
  different (generally better) effects than stock Alpha hardware -
  notably `u`/`v` (vertical explode scroll / slow scroll right on XDF, vs.
  Alpha's rarely-implemented "Explode"/"Clock" modes) and adds `w`/`x`
  (slow vertical scroll up/down) with no Alpha equivalent at all.
- **Extended effects** (Appendix D) - reached via basic code `n` (Invoke
  Extended Effect) followed by a second code, `0`-`9`/`A`-`Z`-ish. XDF adds
  a large number of these beyond what any real Alpha/Betabrite sign has:
  fades, six colour-split-scroll variants (splits red/green pixels and
  scrolls them separately/oppositely - looks best on plain yellow text,
  since yellow is rendered as both colors together), cover/reveal
  scroll-wipe combos, fast/slow drop-down, etc. `AlphaSign::Modes` has the
  full documented set with XDF's own effect descriptions in comments.
- `AUTOMODE` (`o`, or its XDF-added alias `d`) steps through a pseudo-random
  selection of both tiers, excluding a handful of effects XDF deliberately
  omits from rotation (Hold, Flash, plain Rotate, Fade, Colour Split
  Scrolls, Progressive Full Scroll Up) for being boring, disruptive, or
  too CPU-heavy to run unattended.
- Colour-split-scroll effects are notably CPU-intensive - full-speed on
  modern (FDS-101 v4.01) boards for most configurations, but can drop to
  half/quarter speed on older FDS-CB2 boards or larger fibre-interconnect
  displays. Not something to worry about for occasional use, but worth
  knowing if a message using one looks sluggish.

### Default settings

Every new Text file (Priority Text File included) starts from: 7-high
standard font, Auto Colour, Fill position (assembly starts on the top
line), AutoMode effect, centred proportional spacing, normal width,
flashing/colour-shift off, speed 3 (~4.5s pause). The Timeout Message (see
below) instead defaults to Hold mode, red, so a plain-ASCII timeout
message displays sensibly without needing any control codes.

This app's own defaults (`fill`/`automode` for normal messages,
`middle`/`hold`/red for the priority override) intentionally mirror this,
except normal messages also default to `label: "A"`, matching XDF's
documented default memory layout (one full-page Text file per label,
starting at `A`).

## Priority Text File and Timeout Message

Two special, fixed-size (128 byte), single-buffered message slots that sit
outside the normal file system - reconfiguring memory doesn't erase them:

- **Priority Text File** (label `0`): once written, displays immediately
  and overrides every normal file until it's erased or superseded by the
  Timeout Message. `AlphaSign::TextFile.new(..., priority: true)` targets
  this; the web/serial API exposes it as `POST/DELETE /priority`.
- **Timeout Message** (Alpha 2.0 `Set Timeout Message`, command `0x54`):
  displays only if the sign receives *nothing* addressed to it (including
  garbage/corrupted traffic) for a configured period - a "controlling PC
  went away" indicator. Not implemented in this app; would need its own
  `raw` call today (`master command 0x54` + 3-digit ASCII timeout period +
  optional message body).

## Run Time / Run Day scheduling

Alpha's standard mechanism for making a Text file appear/disappear on a
schedule (`0x29` Set Run Time Table, `0x32` Set Run Day Table, or as part
of the Memory Configuration command) is fully supported by XDF and behaves
as documented in the base Alpha spec, with the ambiguity resolved in
XDF's favor of "runs from Start Time up to (not including) Stop Time, on
days matching the Start/Stop Day mask" - not "continuously from Start
Time-on-Start-Day through to Stop-Time-on-Stop-Day". Not implemented in
this app; a natural next feature (e.g. "only show this message 9am-5pm
weekdays") would use these commands directly via `raw`, or would justify
adding first-class `AlphaSign` support if it's worth building properly.

## Beeper

Special Function `0x28`. XDF supports single beep, triple beep, and a
programmable repeat-count beep (frequency parameter is accepted but
ignored - the piezo beeper is a fixed frequency), plus "silence
immediately." The "speaker on" (continuous tone) sub-command that real
Alpha signs support is deliberately *not* implemented by XDF, since a
corrupted message could otherwise trigger a nuisance continuous beep.

## Aux port / misc IO control

Character attribute codes exist to toggle RTS on the RS232 port, and two
opto-isolated general-purpose outputs (IO1/IO2, available on some Aurora
63 units via a 6-pin mini-DIN next to the power inlet) in sync with
message display - e.g. trigger an external buzzer or light exactly when a
particular message appears. Not implemented in this app. IO1/IO2 aren't
available on the older FDS-CB2 control board.

## Time and date display

Live time/date can be embedded directly in message text (`0x13` for time,
`0x0B` + format code for date, or XDF's own `0x0E` + format code for a
formatted time display that doesn't force one global format for the whole
message like the plain `0x13` code does). Formats extend well past the
base Alpha spec - seconds, blinking colon, AM/PM, and several date layouts
with full 4-digit years. Not implemented in this app yet, but would be a
straightforward `raw`-command addition since it doesn't need any state
beyond the control codes themselves.

---

Source: Ferrograph *Extended Display Firmware User Guide*, v4.26
(supplied directly by the display owner - not redistributed here).
Cross-checked in places against the public
[msparks/alphasign](https://github.com/msparks/alphasign) Python library
and the [Alpha-American protocol manual](https://www.alpha-american.com/alpha-manuals/M-Protocol.pdf)
for the parts of the base Alpha protocol XDF doesn't restate.
