"use strict";

// Tests for web_app/public/pixel_grid.js - the picture logic behind the
// Image card. Run with `node --test test/web_app/` or `rake test` (which
// runs these alongside the Ruby suite; see the Rakefile).

const test = require("node:test");
const assert = require("node:assert/strict");
const PixelGrid = require("../../web_app/public/pixel_grid.js");

const {
  clampInt, nearestColorIndex, ditherToDots, naturalTargetSize,
  encodePixels, decodePixels, resizeCodes, cellsBetween, paintLine,
  chipFraction, fitCellSize, SIGN_WIDTH, SIGN_HEIGHT
} = PixelGrid;

const OFF = 0, RED = 1, GREEN = 2, YELLOW = 3;

// Builds the RGBA buffer a canvas would hand us, from a grid of [r,g,b].
function imageDataFrom(rows) {
  const height = rows.length;
  const width = rows[0].length;
  const data = new Uint8ClampedArray(width * height * 4);
  rows.forEach((row, y) => row.forEach(([r, g, b], x) => {
    const i = (y * width + x) * 4;
    data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = 255;
  }));
  return { imageData: { data }, width, height };
}

function gridOf(width, height, drawn = "") {
  const codes = new Uint8Array(width * height);
  decodePixels(drawn).forEach((c, i) => { codes[i] = c; });
  return codes;
}

test("clampInt keeps a value inside the sign's limits", () => {
  assert.equal(clampInt("32", 1, SIGN_WIDTH), 32);
  assert.equal(clampInt("400", 1, SIGN_WIDTH), SIGN_WIDTH);
  assert.equal(clampInt("0", 1, SIGN_HEIGHT), 1);
  assert.equal(clampInt("", 1, SIGN_HEIGHT), 1, "an empty field falls back to the minimum, not NaN");
  assert.equal(clampInt("abc", 4, 16), 4);
});

test.describe("nearestColorIndex", () => {
  test("maps each LED primary to its own palette slot", () => {
    assert.equal(nearestColorIndex(0, 0, 0), OFF);
    assert.equal(nearestColorIndex(255, 0, 0), RED);
    assert.equal(nearestColorIndex(0, 255, 0), GREEN);
    assert.equal(nearestColorIndex(255, 255, 0), YELLOW);
  });

  // The bug this guards: an earlier version matched against softened
  // display colours, which put white nearer to green than to yellow and
  // turned white text into green speckle. Yellow is both LEDs lit - the
  // brightest thing the sign can do - so white must land there.
  test("maps white to yellow, the brightest the sign can manage", () => {
    assert.equal(nearestColorIndex(255, 255, 255), YELLOW);
    assert.equal(nearestColorIndex(200, 200, 200), YELLOW);
  });

  test("maps dark tones to off", () => {
    assert.equal(nearestColorIndex(20, 20, 20), OFF);
    assert.equal(nearestColorIndex(60, 0, 0), OFF, "a dim red is nearer black than full red");
  });
});

test.describe("ditherToDots", () => {
  test("without dithering, solid colour stays solid", () => {
    const { imageData, width, height } = imageDataFrom([
      [[255, 0, 0], [255, 0, 0]],
      [[255, 0, 0], [255, 0, 0]]
    ]);
    const codes = ditherToDots(imageData, width, height, false);
    assert.equal(encodePixels(codes), "1111");
  });

  // Why the Solid option exists: on a hard edge, error diffusion spills
  // colour into neighbours that were meant to stay dark. (100,0,0) is dim
  // enough that nearest-colour drops it entirely - the error dithering
  // then has to put somewhere.
  test("dithering spreads a mid-tone across pixels; solid mode does not", () => {
    const mid = [[[100, 0, 0], [100, 0, 0], [100, 0, 0], [100, 0, 0]]];
    const { imageData, width, height } = imageDataFrom(mid);
    assert.equal(encodePixels(ditherToDots(imageData, width, height, false)), "0000",
                 "nearest-colour drops a dim red entirely - the row goes dark");

    const { imageData: again } = imageDataFrom(mid);
    const dithered = encodePixels(ditherToDots(again, width, height, true));
    assert.notEqual(dithered, "0000",
                    "dithering accumulates the dropped error until a pixel lights, " +
                    "approximating a brightness the sign has no way to display");
  });

  test("returns one code per pixel, row-major", () => {
    const { imageData, width, height } = imageDataFrom([
      [[255, 0, 0], [0, 255, 0], [255, 255, 0]],
      [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
    ]);
    assert.equal(encodePixels(ditherToDots(imageData, width, height, false)), "123000");
  });
});

test.describe("naturalTargetSize", () => {
  // Never scale up: enlarging a small source can't add detail, it just
  // smears whole LEDs across what were crisp pixel edges.
  test("leaves anything that already fits at its exact size", () => {
    assert.deepEqual(naturalTargetSize(16, 16), { width: 16, height: 16 });
    assert.deepEqual(naturalTargetSize(1, 1), { width: 1, height: 1 });
    assert.deepEqual(naturalTargetSize(SIGN_WIDTH, SIGN_HEIGHT), { width: SIGN_WIDTH, height: SIGN_HEIGHT });
  });

  test("scales oversized artwork down, preserving aspect ratio", () => {
    assert.deepEqual(naturalTargetSize(270, 32), { width: 135, height: 16 },
                     "exactly double the display: both dimensions halve");
    assert.deepEqual(naturalTargetSize(1000, 100), { width: 135, height: 14 },
                     "a wide banner is limited by width, so it doesn't fill the height");
    assert.deepEqual(naturalTargetSize(200, 100), { width: 32, height: 16 },
                     "a squarer image is limited by height instead");
  });

  test("never rounds a dimension away to nothing", () => {
    const { width, height } = naturalTargetSize(4000, 3);
    assert.ok(width >= 1 && height >= 1);
  });
});

test.describe("pixel encoding", () => {
  test("round-trips through the wire's one-digit-per-pixel form", () => {
    const codes = Uint8Array.from([0, 1, 2, 3, 3, 2, 1, 0]);
    assert.equal(encodePixels(codes), "01233210");
    assert.deepEqual(Array.from(decodePixels("01233210")), Array.from(codes));
  });

  test("decodes an empty picture to an empty grid", () => {
    assert.equal(decodePixels("").length, 0);
  });
});

test.describe("resizeCodes", () => {
  test("keeps the drawing, anchored top-left, when growing", () => {
    const codes = resizeCodes(decodePixels("12" + "34"), 2, 2, 3, 3);
    assert.equal(encodePixels(codes), "120" + "340" + "000");
  });

  test("crops rather than rescaling when shrinking", () => {
    const codes = resizeCodes(decodePixels("123" + "456" + "789"), 3, 3, 2, 2);
    assert.equal(encodePixels(codes), "12" + "45");
  });

  test("handles a change in one dimension only", () => {
    assert.equal(encodePixels(resizeCodes(decodePixels("12" + "34"), 2, 2, 2, 1)), "12");
    assert.equal(encodePixels(resizeCodes(decodePixels("12" + "34"), 2, 2, 2, 3)), "12" + "34" + "00");
  });
});

test.describe("cellsBetween", () => {
  // Without this, a fast drag paints only where the sparse pointer events
  // happened to land, so a stroke comes out as a dotted line.
  test("fills in every cell along a horizontal drag", () => {
    const cells = cellsBetween({ x: 2, y: 4 }, { x: 6, y: 4 });
    assert.deepEqual(cells.map((c) => c.x), [2, 3, 4, 5, 6]);
    assert.ok(cells.every((c) => c.y === 4));
  });

  test("walks a diagonal one cell at a time", () => {
    assert.deepEqual(cellsBetween({ x: 0, y: 0 }, { x: 3, y: 3 }),
                     [{ x: 0, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 2 }, { x: 3, y: 3 }]);
  });

  test("works backwards and upwards too", () => {
    assert.deepEqual(cellsBetween({ x: 3, y: 3 }, { x: 0, y: 0 }),
                     [{ x: 3, y: 3 }, { x: 2, y: 2 }, { x: 1, y: 1 }, { x: 0, y: 0 }]);
    assert.deepEqual(cellsBetween({ x: 2, y: 5 }, { x: 2, y: 2 }).map((c) => c.y), [5, 4, 3, 2]);
  });

  test("a stroke that never left its cell is just that cell", () => {
    assert.deepEqual(cellsBetween({ x: 7, y: 1 }, { x: 7, y: 1 }), [{ x: 7, y: 1 }]);
  });

  test("a shallow diagonal is continuous - no gaps to see through", () => {
    const cells = cellsBetween({ x: 0, y: 0 }, { x: 8, y: 3 });
    assert.equal(cells.length, 9, "one cell per column crossed");
    cells.slice(1).forEach((cell, i) => {
      const previous = cells[i];
      assert.ok(Math.abs(cell.x - previous.x) <= 1 && Math.abs(cell.y - previous.y) <= 1,
                `step from ${JSON.stringify(previous)} to ${JSON.stringify(cell)} skips a cell`);
    });
  });
});

test.describe("paintLine", () => {
  test("paints the whole segment into the grid", () => {
    const codes = gridOf(4, 2);
    assert.equal(paintLine(codes, 4, 2, { x: 0, y: 0 }, { x: 3, y: 0 }, RED), true);
    assert.equal(encodePixels(codes), "1111" + "0000");
  });

  test("reports no change when the cells already hold that colour", () => {
    const codes = gridOf(4, 1, "1111");
    assert.equal(paintLine(codes, 4, 1, { x: 0, y: 0 }, { x: 3, y: 0 }, RED), false,
                 "a drag inside already-painted cells shouldn't force a re-render");
  });

  test("erases by painting off", () => {
    const codes = gridOf(3, 1, "111");
    paintLine(codes, 3, 1, { x: 1, y: 0 }, { x: 1, y: 0 }, OFF);
    assert.equal(encodePixels(codes), "101");
  });

  // A stroke can be captured beyond the canvas edge, and must not wrap
  // round onto the opposite side of the row.
  test("ignores cells outside the grid", () => {
    const codes = gridOf(3, 2);
    assert.equal(paintLine(codes, 3, 2, { x: 1, y: 0 }, { x: 5, y: 0 }, RED), true);
    assert.equal(encodePixels(codes), "011" + "000");

    const untouched = gridOf(3, 2);
    assert.equal(paintLine(untouched, 3, 2, { x: -4, y: -1 }, { x: -1, y: -1 }, RED), false);
    assert.equal(encodePixels(untouched), "000000");
  });
});

test.describe("chipFraction", () => {
  // Mirrors AlphaSign::DotsFile#lit_chip_fraction: each pixel has two LED
  // chips, and yellow lights both. Keep these in step with
  // test/alpha_sign/dots_file_test.rb - the browser warns before sending
  // and serial_api enforces, so they have to agree.
  test("counts yellow as two chips and red/green as one", () => {
    assert.equal(chipFraction(decodePixels("0000")), 0);
    assert.equal(chipFraction(decodePixels("3333")), 1, "all yellow lights every chip");
    assert.equal(chipFraction(decodePixels("1111")), 0.5);
    assert.equal(chipFraction(decodePixels("2222")), 0.5);
    assert.equal(chipFraction(decodePixels("1230")), (1 + 1 + 2) / 8);
  });

  test("puts an all-yellow picture over the 50% safety limit", () => {
    assert.ok(chipFraction(decodePixels("33")) > 0.5);
    assert.ok(chipFraction(decodePixels("11")) <= 0.5, "all red sits exactly at the limit");
  });
});

test.describe("fitCellSize", () => {
  test("fills the space available", () => {
    assert.equal(fitCellSize(640, 32), 20);
    assert.equal(fitCellSize(676, 135), 5);
  });

  test("caps enlargement so a tiny icon isn't rendered enormous", () => {
    assert.equal(fitCellSize(676, 8), 20);
  });

  test("never drops below a visible cell, even with no room", () => {
    assert.equal(fitCellSize(0, 135), 2);
    assert.equal(fitCellSize(-10, 135), 2, "a hidden panel measures as nothing");
  });
});
