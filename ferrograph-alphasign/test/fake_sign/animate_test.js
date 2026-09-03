"use strict";

// Tests for tools/fake_sign/public/animate.js - the window maths that
// turns a composed message into what the display shows at a moment in
// time. Run with `rake test:js` or `node --test "test/**/*_test.js"`.

const test = require("node:test");
const assert = require("node:assert/strict");
const Animate = require("../../tools/fake_sign/public/animate.js");

const { WIDTH, HEIGHT, blank, place, mask, ordering, render, duration } = Animate;

const TIMINGS = {
  rotate_pixels_per_second: 30,
  flash_period_seconds: 1,
  transition_seconds: 0.7
};

// A canvas whose every pixel is lit, so "what is on screen" is purely a
// question of geometry.
function solidCanvas(width = WIDTH, height = HEIGHT, colour = 1) {
  return Array.from({ length: height }, () => new Array(width).fill(colour));
}

function frameFor(motion, canvas = solidCanvas(), overrides = {}) {
  return Object.assign({
    motion,
    pause: 4.5,
    transition: 0.7,
    canvas: { width: canvas[0].length, height: canvas.length, pixels: canvas }
  }, overrides);
}

function litColumns(pixels) {
  const columns = [];
  for (let x = 0; x < WIDTH; x++) {
    if (pixels.some((row) => row[x] !== 0)) columns.push(x);
  }
  return columns;
}

function litRows(pixels) {
  return pixels.map((row, y) => (row.some((v) => v !== 0) ? y : -1)).filter((y) => y >= 0);
}

test.describe("place", () => {
  test("copies the canvas at an offset and clips the rest", () => {
    const canvas = solidCanvas(10, 2);
    const out = place(canvas, 3, 1, 8, 4);
    assert.deepEqual(out[0], new Array(8).fill(0), "nothing above the offset");
    assert.deepEqual(out[1].slice(0, 3), [0, 0, 0], "nothing left of the offset");
    assert.deepEqual(out[1].slice(3), [1, 1, 1, 1, 1]);
    assert.deepEqual(out[3], new Array(8).fill(0), "canvas is only 2 rows tall");
  });

  test("a negative offset clips from the left rather than wrapping", () => {
    const canvas = [[1, 2, 3, 4]];
    const out = place(canvas, -2, 0, 4, 1);
    assert.deepEqual(out[0], [3, 4, 0, 0]);
  });

  // Regression: elapsed time gives fractional offsets, and indexing an
  // array at 0.9 silently returns undefined - which blanked the whole
  // display in the browser while every test here, using round numbers,
  // passed happily.
  test("a fractional offset lands on whole pixels instead of vanishing", () => {
    const canvas = [[1, 2, 3, 4]];
    assert.deepEqual(place(canvas, 1.4, 0, 6, 1)[0], [0, 1, 2, 3, 4, 0]);
    assert.deepEqual(place(canvas, 1.6, 0, 6, 1)[0], [0, 0, 1, 2, 3, 4]);
    assert.deepEqual(place(canvas, 0, 0.4, 4, 2)[0], [1, 2, 3, 4]);
  });
});

test.describe("hold", () => {
  test("shows the message where it was composed, unmoving", () => {
    const frame = frameFor("hold");
    const early = render(frame, 0, TIMINGS);
    const later = render(frame, 3, TIMINGS);
    assert.deepEqual(early, later);
    assert.equal(litColumns(early).length, WIDTH);
  });
});

test.describe("rotate", () => {
  // Appendix C: "slow rotate (travel) to the left, continuous updates".
  test("enters from the right edge", () => {
    const pixels = render(frameFor("rotate", solidCanvas(60, HEIGHT)), 0, TIMINGS);
    assert.deepEqual(litColumns(pixels), [], "at t=0 the message is still off-screen");
  });

  test("keeps travelling at times that aren't whole seconds", () => {
    const frame = frameFor("rotate", solidCanvas(60, HEIGHT));
    const early = litColumns(render(frame, 1.4966, TIMINGS));
    const later = litColumns(render(frame, 2.1231, TIMINGS));
    assert.ok(early.length > 0, "the message is on screen at a fractional time");
    assert.ok(later[0] < early[0], "and it has moved leftwards since");
  });

  test("travels leftwards at the configured rate", () => {
    const frame = frameFor("rotate", solidCanvas(60, HEIGHT));
    // One second at 30px/s puts the message's left edge 30 columns in from
    // the right, so columns 105..134 are lit.
    const pixels = render(frame, 1, TIMINGS);
    assert.deepEqual(litColumns(pixels), Array.from({ length: 30 }, (_, i) => WIDTH - 30 + i));
  });

  test("eventually leaves the display entirely", () => {
    const frame = frameFor("rotate", solidCanvas(60, HEIGHT));
    const total = duration(frame, TIMINGS);
    assert.equal(litColumns(render(frame, total, TIMINGS)).length, 0);
  });

  test("its duration covers the whole journey across the display", () => {
    const frame = frameFor("rotate", solidCanvas(60, HEIGHT));
    assert.equal(duration(frame, TIMINGS), (60 + WIDTH) / 30);
  });
});

test.describe("flash", () => {
  test("alternates between the message and darkness", () => {
    const frame = frameFor("flash");
    assert.ok(litColumns(render(frame, 0, TIMINGS)).length > 0, "on at the start");
    assert.equal(litColumns(render(frame, 0.6, TIMINGS)).length, 0, "off in the second half");
    assert.ok(litColumns(render(frame, 1.1, TIMINGS)).length > 0, "on again next cycle");
  });
});

test.describe("rolls", () => {
  test("roll_left brings the message in from the right", () => {
    const frame = frameFor("roll_left");
    assert.equal(litColumns(render(frame, 0, TIMINGS)).length, 0);
    // Half way in, about half the display is covered - "about" because the
    // offset lands on a whole pixel and 135 is odd.
    const half = litColumns(render(frame, 0.35, TIMINGS));
    assert.ok(Math.abs(half.length - WIDTH / 2) <= 1, `expected ~${WIDTH / 2} columns, got ${half.length}`);
    assert.equal(half[half.length - 1], WIDTH - 1, "the leading edge is at the right");
    assert.equal(litColumns(render(frame, 0.7, TIMINGS)).length, WIDTH);
  });

  test("roll_right brings it in from the left", () => {
    const frame = frameFor("roll_right");
    const half = render(frame, 0.35, TIMINGS);
    assert.equal(litColumns(half)[0], 0, "the leading edge is at the left");
    assert.equal(litColumns(render(frame, 0.7, TIMINGS)).length, WIDTH);
  });

  test("roll_up brings it in from below and roll_down from above", () => {
    const up = render(frameFor("roll_up"), 0.35, TIMINGS);
    assert.equal(litRows(up)[0], Math.round(HEIGHT / 2), "the bottom half is filled first");

    const down = render(frameFor("roll_down"), 0.35, TIMINGS);
    assert.equal(litRows(down)[0], 0, "the top half is filled first");
  });

  test("a slow effect just takes longer, via its transition", () => {
    const fast = frameFor("roll_left", solidCanvas(), { transition: 0.7 });
    const slow = frameFor("roll_left", solidCanvas(), { transition: 1.4 });
    assert.deepEqual(render(fast, 0.35, TIMINGS), render(slow, 0.7, TIMINGS),
                     "half way through is half way through, whatever the duration");
  });
});

test.describe("wipes", () => {
  // A wipe reveals in place - nothing moves, unlike a roll.
  test("wipe_right reveals from the left edge", () => {
    const columns = litColumns(render(frameFor("wipe_right"), 0.35, TIMINGS));
    assert.equal(columns[0], 0);
    assert.ok(columns.length < WIDTH);
    assert.ok(Math.abs(columns.length - WIDTH / 2) <= 1);
  });

  test("wipe_left reveals from the right edge", () => {
    const columns = litColumns(render(frameFor("wipe_left"), 0.35, TIMINGS));
    assert.equal(columns[columns.length - 1], WIDTH - 1);
  });

  test("wipe_down reveals from the top and wipe_up from the bottom", () => {
    assert.equal(litRows(render(frameFor("wipe_down"), 0.35, TIMINGS))[0], 0);
    assert.equal(litRows(render(frameFor("wipe_up"), 0.35, TIMINGS)).pop(), HEIGHT - 1);
  });

  test("every wipe ends with the whole message showing", () => {
    ["wipe_left", "wipe_right", "wipe_up", "wipe_down"].forEach((motion) => {
      assert.equal(litColumns(render(frameFor(motion), 0.7, TIMINGS)).length, WIDTH, motion);
    });
  });
});

test.describe("implode and explode", () => {
  test("implode_wipe reveals from both edges inwards", () => {
    const columns = litColumns(render(frameFor("implode_wipe"), 0.35, TIMINGS));
    assert.equal(columns[0], 0, "left edge revealed");
    assert.equal(columns[columns.length - 1], WIDTH - 1, "right edge revealed too");
    assert.ok(!columns.includes(Math.floor(WIDTH / 2)), "the centre is still dark");
  });

  test("explode_wipe reveals from the centre outwards", () => {
    const columns = litColumns(render(frameFor("explode_wipe"), 0.35, TIMINGS));
    assert.ok(columns.includes(Math.floor(WIDTH / 2)), "the centre is revealed first");
    assert.ok(!columns.includes(0), "the edges are still dark");
  });

  test("explode_vertical splits the display into halves that part", () => {
    const pixels = render(frameFor("explode_vertical"), 0.35, TIMINGS);
    assert.ok(litRows(pixels).length > 0);
    assert.equal(litColumns(render(frameFor("explode_vertical"), 0.7, TIMINGS)).length, WIDTH);
  });
});

test.describe("decorative effects", () => {
  // These are impressions rather than reproductions, so the assertions are
  // about shape: they start dark, end complete, and scatter in between.
  ["dissolve", "snow", "slide", "switch", "interlock_wipe"].forEach((motion) => {
    test(`${motion} starts empty, fills in, and completes`, () => {
      const frame = frameFor(motion);
      assert.equal(litColumns(render(frame, 0, TIMINGS)).length, 0);
      const middle = render(frame, 0.35, TIMINGS);
      const litCount = middle.flat().filter((v) => v !== 0).length;
      assert.ok(litCount > 0 && litCount < WIDTH * HEIGHT, "partially revealed");
      assert.equal(render(frame, 0.7, TIMINGS).flat().filter((v) => v !== 0).length, WIDTH * HEIGHT);
    });
  });

  test("dissolve scatters rather than sweeping", () => {
    const pixels = render(frameFor("dissolve"), 0.35, TIMINGS);
    const columns = litColumns(pixels);
    assert.ok(columns.includes(0) || columns.includes(1), "reaches the left edge early");
    assert.ok(columns.some((x) => x > WIDTH - 3), "and the right edge too");
  });

  test("twinkle keeps the message readable while shimmering", () => {
    const frame = frameFor("twinkle");
    const a = render(frame, 0, TIMINGS);
    const b = render(frame, 0.1, TIMINGS);
    assert.ok(a.flat().filter((v) => v !== 0).length > WIDTH * HEIGHT * 0.5, "most of the message stays lit");
    // Each phase drops a quarter of the pixels, so the counts match while
    // the patterns differ - compare the grids, not the totals.
    assert.notDeepEqual(a, b, "which pixels are dropped changes over time");
  });
});

test.describe("ordering", () => {
  test("is a permutation, and the same one every time", () => {
    const first = ordering(50);
    assert.deepEqual([...first].sort((a, b) => a - b), Array.from({ length: 50 }, (_, i) => i));
    assert.deepEqual(first, ordering(50), "deterministic, so tests and reloads agree");
  });
});

test.describe("duration", () => {
  test("a static effect runs for its transition plus its pause", () => {
    assert.equal(duration(frameFor("hold", solidCanvas(), { transition: 0.7, pause: 4.5 }), TIMINGS), 5.2);
  });

  test("flash runs for its pause alone", () => {
    assert.equal(duration(frameFor("flash", solidCanvas(), { pause: 2.2 }), TIMINGS), 2.2);
  });
});
