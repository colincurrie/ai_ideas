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

## The three file types (and why a picture on its own shows nothing)

The sign's filesystem holds three kinds of file, and only one of them is
ever *displayed*:

| Type | Command | Displayed? |
|---|---|---|
| **Text** | `A` (Write Text) | Yes - text files are the run sequence the sign cycles through |
| **String** | `G` (Write String) | Only when a text file calls it |
| **Dots picture** | `I` (Write Small Dots Picture) | Only when a text file calls it |

Writing a string or a picture just puts it in memory. It appears on the
display solely because a text file's content *calls* it at a particular
point:

```
0x10 <label>   call a String file here
0x14 <label>   call a Dots Picture file here
```

Both are inline control codes inside a text file's message text, which is
how a picture ends up mid-sentence rather than replacing the message.
(`AlphaSign::Protocol::CALL_STRING` / `CALL_DOTS`; AlphaNET's own editor
has the same pair of "insert" actions, for the same reason.)

This caused a real bug in an early version of this project: sending an
image wrote the picture file and nothing else, so the sign had nothing in
its run sequence to show and simply went dark.

### String files

Strings exist for cheap updates. They're **always double buffered**, so
rewriting one swaps its contents in without blanking the display or
disturbing the message calling it - unlike a text file rewrite (which
blanks by default, in Full Blank/single-buffered mode) or a memory
reconfiguration (which erases every file). That makes them the right home
for a value that changes often inside a message that stays put.

Two constraints from the manual:

- A String file **cannot call another String file**.
- Alpha's 125-byte string limit doesn't apply on XDF - its dynamic double
  buffering lifts it to roughly 10K per memory page - but a string still
  has to fit the size reserved for it in the memory configuration.

The memory configuration entry for a string is:

```
String file: <label><"B"><lock: "L"/"U"><size, 4 hex digits><"0000">
```

(The manual's own worked example for three 1K strings A, B and C is
`ABL04000000BBL04000000CBL04000000`, which `AlphaSign::MemoryConfig#string_file`
reproduces byte for byte.)

### Labels are one shared namespace

A memory configuration lists each label once, with a type, so a label
can't be both a text file and a picture - `SerialApi::Layout` refuses that
rather than emitting two contradictory entries for the same label.

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

## Dots Picture files and Memory Configuration

Images are shown as a Small Dots Picture file (command `I`) - the only Dots
format XDF supports: "there is no support for large (AlphaVision) Dots
Picture files (which are not supported on the Alpha 4000 series signs,
either), as these would add excessive overhead to the internal filesystem."
There's no RGB dots format either - this hardware has no RGB pixels.

**Provenance caveat - read this before trusting the numbers below.** XDF's
manual just says the Dots Picture wire format is "as defined in the Alpha
Protocol Manual" and doesn't restate it, and that manual wasn't reachable
from this environment to verify directly (network egress to
alpha-american.com is blocked here). `AlphaSign::DotsFile` and
`AlphaSign::MemoryConfig` are reconstructed instead from a third-party
open-source Alpha-protocol packet generator,
[darinfranklin/bbxml](https://github.com/darinfranklin/bbxml)'s
`xml/alphasign.xsl`. Confidence is reasonably good - its Run Time Table
special values (`always`→`0xFF`, `never`→`0xFE`, `all day`→`0xFD`)
independently match what XDF's own manual documents for the same field
elsewhere - but this is still a lower-confidence corner of this library
than the rest of it. Test with a small image before trusting it for
anything that matters.

### Defining a Dots file: Memory Configuration

Before a label can be *written* to as a Dots Picture (or, for that matter,
before any custom Text file sizing is needed), it has to be *defined* via
the **Define Memory Configuration** special function (`E` + sub-code `$`,
0x24). **This replaces the sign's entire file layout, not just the label
being defined** - any label not included in the new configuration stops
existing. See "Flexible Paged Memory Filesystem" above for why (each
memory page is its own self-contained filesystem that gets wholesale
replaced on reconfiguration).

Because of that, `serial_api` sends one as rarely as it can: never for
text-only use (XDF's power-on default layout already provides a text file
per label), and when it must, it immediately re-sends every file's
contents, since they were just erased. See `serial_api/layout.rb` and the
README's "Memory configuration" section.

Each file gets one fixed-width entry, concatenated back to back with no
separator (entries are self-describing by their own field widths, so the
receiver doesn't need a count or delimiter):

```
Text file:  <label><"A"><lock: "L"/"U"><size, 4 hex digits><start time, 2 hex><stop time, 2 hex>
Dots file:  <label><"D"><lock: "L"/"U"><height, 2 hex><width, 2 hex><colour depth, 4 chars>
```

Start/stop time reuse the same Run Time Table special values as message
scheduling (see "Run Time / Run Day scheduling" below) - `AlphaSign::MemoryConfig::ALWAYS`
(`"FF"`) as the start time makes a file permanently enabled and makes the
stop time irrelevant ("if used in this way, the Stop Time is totally
ignored," per the manual).

Colour depth is a 4-character code: `"1000"` (monochrome, inherits
whatever colour is set via the normal text colour codes), `"2000"`
(3-colour: red/green/yellow) or `"4000"` (Alpha's 8-colour depth, which
collapses to the same 3-colour output as `"2000"` on this 2-colour
hardware - so `AlphaSign::MemoryConfig` only exposes `"1000"`/`"2000"`,
via `monochrome:`).

### Writing pixel data

Once a label is defined as a Dots file, `I` + label + dimensions + pixel
data updates its contents:

```
"I" <label> <height, 2 hex digits> <width, 2 hex digits> <row>...<row>
```

Each row is `width` single-character pixel codes (see below), followed by
a literal CR (0x0D) marking the row's end - sent as the 3-byte escape
`"_0D"` (three literal ASCII characters: `_`, `0`, `D`) rather than a raw
0x0D byte, because a raw 0x0D is the New Line control code (Appendix A)
and would be misinterpreted as one if sent literally inside message data.

Per-pixel colour codes (bare digits, no `0x1C` prefix - contrast with text
colours):

| Code | Colour | Alpha-defined |
|---|---|---|
| `0` | Off | Off |
| `1` | Red | Red |
| `2` | Green | Green |
| `3` | Yellow | Amber |
| `4`-`8` | (collapse to Red/Green/Yellow, same pattern as text colours) | Dim Red/Dim Green/Brown/Orange/Yellow |

`AlphaSign::DotsColors` only exposes the 4 practically-distinct codes, same
reasoning as `AlphaSign::Colors`.

Protocol limits: 32 rows (height) x 255 columns (width) maximum. The
Aurora 63 is a 16-pixel-tall, 135-pixel-wide matrix, so a picture larger
than that either gets cropped (fixed-format effects) or scrolls through in
full (Rotate/travelling effect).

### LED safety - the one hard constraint here

The manual is explicit and physical about this one, not just a protocol
nicety:

> The Ferrograph Display Hardware is NOT designed to cope with the
> excessive loading that would result if too many LEDs are turned on
> simultaneously... it is recommended that no more than 50% of LED chips
> are illuminated simultaneously. Remember that the yellow colour is
> actually a mix of red and green, so each yellow dot counts as two chips.

`AlphaSign::DotsFile#lit_chip_fraction` implements exactly this weighting
(yellow = 2 chips, red/green = 1, off = 0, against a denominator of 2 per
pixel = "every pixel yellow"). `serial_api`'s `POST /image` refuses to
send anything over 50% unless `force: true` is passed, and the web app's
client-side dithering computes and displays the same number before the
user even hits Send - see `web_app/public/app.js`'s `updateChipFraction`.
This is enforced server-side (not just in the UI) deliberately, since it's
a physical safety constraint, not a preference.

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
[msparks/alphasign](https://github.com/msparks/alphasign) Python library,
the [Alpha-American protocol manual](https://www.alpha-american.com/alpha-manuals/M-Protocol.pdf)
for the parts of the base Alpha protocol XDF doesn't restate, and
[darinfranklin/bbxml](https://github.com/darinfranklin/bbxml) for the Dots
Picture/Memory Configuration wire format specifically (see "Dots Picture
files and Memory Configuration" above for the confidence caveat that
applies only to that section).
