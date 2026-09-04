# Calibrating the fake sign against the real one

The preview's *geometry* comes from the manual. Its *speeds* mostly don't —
the manual states the pause between frames exactly and says nothing about
how fast anything moves. Those numbers live in `tools/fake_sign/timings.rb`,
each marked `ESTIMATE`. This is how to replace them with measurements.

Short version: **five clips, about ten minutes.** Film straight-on, at 60fps
if your phone offers it, and say the test name at the start of each clip so
they can be told apart.

## What is already known (don't spend film on it)

Section 26 gives the pause between fixed-format frames outright:

| Speed | Pause |
|---|---|
| 1 | 17 s |
| 2 | 9 s |
| 3 | 4.5 s (default) |
| 4 | 2.2 s |
| 5 | 1 s |

Worth one confirming clip (test 5 below), not more.

## Test 1 — Rotate speed *(the most valuable one)*

`ROTATE_PIXELS_PER_SECOND`. Everything about a travelling message depends
on it, and the manual only says "slow".

Measure it with a **picture**, not text: a picture's width in columns is
exact, where a glyph's isn't (our font is an approximation, so timing text
would measure two unknowns at once).

1. In the web app, draw a **1 wide × 16 high** image, all one colour, and
   save it as label `P`.
2. Compose a message containing *only* that image — insert it, nothing else.
3. Position **middle**, effect **rotate**, speed **5**.
4. Film from before the line appears at the right edge until after it
   leaves at the left.

**Reading it:** time from the column first appearing at the right edge to
it disappearing at the left. It travels 135 + 1 = 136 columns, so
`pixels per second = 136 / seconds`.

## Test 2 — Transition duration

`TRANSITION_SECONDS`: how long a roll or wipe takes to complete.

```
bin/alphasign send -d /dev/tty.usbserial-XXXX -m wipe_right -s 1 "WIPE TEST"
```

Speed 1 gives a 17-second pause, so the transition sits alone with nothing
crowding it.

**Reading it:** time from the first pixel appearing to the message being
fully shown. Repeat with `-m roll_left` if you want to know whether rolls
and wipes differ — I've assumed they don't.

## Test 3 — Are the "half speed" effects exactly half?

Appendix C calls `t`, `v`, `w`, `x` "half speed" versions. Worth one clip to
confirm the factor is really 2.

```
bin/alphasign send -d /dev/tty.usbserial-XXXX -m roll_left -s 1 "FAST"
bin/alphasign send -d /dev/tty.usbserial-XXXX -m compressed_rotate -s 1 "SLOW"
```

**Reading it:** the two transition times, and their ratio.

## Test 4 — Flash rate

`FLASH_PERIOD_SECONDS`.

```
bin/alphasign send -d /dev/tty.usbserial-XXXX -m flash "FLASH"
```

**Reading it:** count the flashes over 10 seconds. Note whether the on and
off halves look equal — I've assumed they are.

## Test 5 — Pause, confirmed

One clip that both confirms the table above and shows how the run sequence
hands over. Send two files so the sign has something to alternate between:

```
bin/alphasign send -d /dev/tty.usbserial-XXXX -l A -m hold -s 5 "ONE"
bin/alphasign send -d /dev/tty.usbserial-XXXX -l B -m hold -s 5 "TWO"
```

**Reading it:** how long each is on screen. Should be about 1 second at
speed 5. Repeat at `-s 1` and it should be about 17.

## Optional — AutoMode

```
bin/alphasign send -d /dev/tty.usbserial-XXXX -m automode "AUTO"
```

Film a minute or so. This one isn't a number: it's "which effects, in what
order", which the manual doesn't document at all ("every effect under the
sun"). Currently the preview just holds the message still and marks it
approximated.

## What to do with the clips

Send them over. The numbers go into `tools/fake_sign/timings.rb` — one
constant each, all in the same place for exactly this reason — and the
`ESTIMATED` list shrinks. Anything still on that list is what the preview
still marks as a guess.

## What film cannot settle

Two things stay out of reach whatever you film:

- **The font.** Glyph shapes need the ROM, not a video — a photograph of
  text would let us redraw characters by eye, which is a different and much
  longer job. Until then the preview is wrong about how wide a message is.
- **The read-back reply formats.** Those need `bin/alphasign read` run
  against the sign, not a camera. See the main README.
