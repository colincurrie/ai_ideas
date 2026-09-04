# Fake sign

A stand-in for the Ferrograph Aurora 63: a pseudo-terminal that behaves
like the display's serial port, a strict decoder for what arrives on it,
and a live preview of what the sign would be showing.

```
bin/fake-sign
# prints a device path, e.g. /dev/pts/3, and serves http://127.0.0.1:4569

SERIAL_DEVICE=/dev/pts/3 bundle exec rackup serial_api/config.ru -o 127.0.0.1 -p 4568
```

Then drive it however you like — `bin/alphasign`, `serial_api`, the web
app — and watch the preview.

## Why the decoder is strict, and written from the manual

`tools/fake_sign/decoder.rb` is deliberately **not** built on
`lib/alpha_sign`. It is written from the XDF firmware manual, and it
rejects rather than tolerates.

A decoder derived from our own encoder would be a mirror: it would accept
whatever we happen to emit and confirm every assumption we already hold.
That is exactly how this project came to send a Dots row terminator of
`"_0D"` — the 3-byte format's escape for `0x0D`, sent inside a 1-byte
frame where `_` is just an underscore — and never noticed, because every
test asserted the same bytes the encoder produced. It took a photograph of
a real sign showing a picture's top row and nothing else.

Fed those same bytes, this decoder says:

```
ERROR at byte 13: row 0 ends with 0x5F, not the 0DH that terminates a row
```

and reproduces the symptom exactly — one row decoded, the rest lost. That
is the entire point of the tool. There's a test pinning it
(`test/fake_sign/decoder_test.rb`).

So the rule for anything added here: **cite the manual, not `lib/`.** If a
check disagrees with our encoder, that disagreement is the finding.

Findings come in two severities, and the difference is meaningful:

- `error` — the sign would reject or misread this. A real bug.
- `warning` — the sign tolerates it, and the manual says so explicitly
  (an unknown character-set code falls back to 7-high standard; an
  unrecognised command is ignored silently). Probably not what you meant,
  but not broken.

## What it models

- **The default memory configuration.** With no configuration sent, XDF
  defines one text file per memory page, labels from `A` — five on a 128K
  machine, eleven on 256K (§11). Writing to a label outside that set is
  reported as the memory-allocation failure the sign would raise. Use
  `--memory 256` if yours has more fitted.
- **Configuration erasing everything.** The behaviour behind the
  blank-screen bug: defining memory replaces the whole layout and wipes
  every file's contents.
- **The three file types.** Text files are the run sequence; strings and
  pictures only appear where a text file calls them (`0x10`/`0x14`). A
  picture nothing calls renders as nothing, visibly.
- **Placement and colour.** Position codes (§17) and the colour table
  (§21), including how codes `4`-`8` collapse onto the three colours this
  hardware can show.

## What it doesn't

- **Glyph shapes.** `font.rb` is a conventional 5x7 set drawn to the
  metrics the manual describes, not the Aurora's ROM, which we don't have.
  Use the preview for layout, colour and which files get called — not to
  decide whether a message fits.
- **Effect *speeds*.** The geometry of every effect comes from Appendix C
  and D and is modelled properly - rotate travels, wipes reveal in place,
  implode and explode split the display. But the manual gives only the
  *pause* between frames (§26: 17 / 9 / 4.5 / 2.2 / 1 seconds, default
  4.5). It never says how fast anything moves, so the scroll rate,
  transition duration and flash rate in `timings.rb` are estimates,
  labelled as such and gathered in one file so measurements can replace
  them. `CALIBRATION.md` says how to measure them off a filmed sign.
- **The decorative extended effects** - twinkle, dissolve, snow, slide and
  the interlocks. The manual names them and describes their character but
  gives no pattern, so these are impressions of the right shape rather than
  reproductions. The preview marks them "approximated".
- **Run-time scheduling.** Run Time and Run Day tables aren't modelled;
  every written text file is treated as being in the run sequence.
- **Read requests.** It logs them and refuses to answer. The reply formats
  come from Alpha's protocol manual rather than XDF's, so answering would
  mean inventing both halves of a conversation and testing one against the
  other — the same circularity this tool exists to avoid. Only a real sign
  can settle those.
