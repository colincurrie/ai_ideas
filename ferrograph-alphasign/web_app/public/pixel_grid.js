"use strict";

// The picture logic behind the Image card, with no DOM in it: palette
// matching and dithering, the pixel-string encoding the wire wants, and the
// grid arithmetic the drawing editor needs (resizing, stroke interpolation,
// zoom, LED load).
//
// It lives apart from app.js so it can be tested directly under `node
// --test` - see test/web_app/pixel_grid_test.js. In the browser it's a
// plain script that hangs one global off window; there's no build step
// here, and adding one to run a few tests would be a poor trade.
(function (root, factory) {
  const api = factory();
  root.PixelGrid = api;
  if (typeof module === "object" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  // Two separate palettes on purpose:
  //
  // MATCH uses the sign's actual LED primaries - a pixel is red LED on,
  // green LED on, both (yellow), or neither. Using softened "nice looking"
  // values here instead skews the colour maths badly: with a muted yellow,
  // plain white ends up nearer to green than to yellow in RGB distance,
  // even though yellow (both LEDs lit) is the brightest thing the sign can
  // do. PREVIEW is only for drawing the on-screen preview, where the
  // softer colours are easier on the eye.
  const MATCH_PALETTE = { off: [0, 0, 0], red: [255, 0, 0], green: [0, 255, 0], yellow: [255, 255, 0] };
  const ORDER = ["off", "red", "green", "yellow"]; // index == the wire's pixel digit code
  const PREVIEW_COLORS = ["#000", "#ff5a5a", "#5aff8a", "#ffe45a"];

  // The Aurora 63's matrix, and the hard ceiling on both the drawing grid
  // and an upload: the protocol allows a bigger picture (up to 255x32) but
  // this sign has nowhere to put one.
  const SIGN_WIDTH = 135;
  const SIGN_HEIGHT = 16;

  function clampInt(value, min, max) {
    const n = Number.parseInt(value, 10);
    if (Number.isNaN(n)) return min;
    return Math.min(max, Math.max(min, n));
  }

  function nearestColorIndex(r, g, b) {
    let best = 0;
    let bestDist = Infinity;
    ORDER.forEach((name, i) => {
      const [pr, pg, pb] = MATCH_PALETTE[name];
      const dist = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2;
      if (dist < bestDist) {
        bestDist = dist;
        best = i;
      }
    });
    return best;
  }

  function distributeError(buf, width, height, x, y, er, eg, eb) {
    const add = (xx, yy, factor) => {
      if (xx < 0 || xx >= width || yy < 0 || yy >= height) return;
      const idx = (yy * width + xx) * 3;
      buf[idx] += er * factor;
      buf[idx + 1] += eg * factor;
      buf[idx + 2] += eb * factor;
    };
    add(x + 1, y, 7 / 16);
    add(x - 1, y + 1, 3 / 16);
    add(x, y + 1, 5 / 16);
    add(x + 1, y + 1, 1 / 16);
  }

  // Quantizes RGBA image data down to the 4-colour dots palette. Returns a
  // flat array of palette indices, one per pixel, row-major - the layout
  // the wire format and the preview canvas both want.
  //
  // +dither+ picks the trade-off: Floyd-Steinberg error diffusion
  // approximates in-between tones by mixing pixels, which is what you want
  // for photos and gradients, but it shreds high-contrast graphics - text
  // and logos come out as red/green confetti instead of readable shapes.
  // With dithering off it's a straight nearest-colour map, so solid areas
  // stay solid.
  function ditherToDots(imageData, width, height, dither = true) {
    const buf = new Float32Array(width * height * 3);
    for (let i = 0; i < width * height; i++) {
      buf[i * 3] = imageData.data[i * 4];
      buf[i * 3 + 1] = imageData.data[i * 4 + 1];
      buf[i * 3 + 2] = imageData.data[i * 4 + 2];
    }

    const codes = new Uint8Array(width * height);
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const idx = y * width + x;
        const r = buf[idx * 3];
        const g = buf[idx * 3 + 1];
        const b = buf[idx * 3 + 2];
        const code = nearestColorIndex(r, g, b);
        codes[idx] = code;
        if (!dither) continue;

        const [pr, pg, pb] = MATCH_PALETTE[ORDER[code]];
        distributeError(buf, width, height, x, y, r - pr, g - pg, b - pb);
      }
    }
    return codes;
  }

  // What size to default the width/height fields to for a freshly loaded
  // image. Anything that already fits the display keeps its exact pixel
  // dimensions - a 16x16 icon stays a 16x16 icon rather than being blown
  // up to fill the panel, which would only invent detail that isn't there.
  function naturalTargetSize(width, height) {
    if (width <= SIGN_WIDTH && height <= SIGN_HEIGHT) return { width, height };
    const scale = Math.min(SIGN_WIDTH / width, SIGN_HEIGHT / height);
    return {
      width: Math.max(1, Math.round(width * scale)),
      height: Math.max(1, Math.round(height * scale))
    };
  }

  // The wire wants one ASCII digit per pixel; everything in here works on
  // palette indices, so these two are the only places that conversion
  // happens.
  function encodePixels(codes) {
    return Array.from(codes).join("");
  }

  function decodePixels(pixels) {
    const codes = new Uint8Array(pixels.length);
    for (let i = 0; i < codes.length; i++) codes[i] = pixels.charCodeAt(i) - 48;
    return codes;
  }

  // Keeps whatever is already drawn, anchored top-left, so nudging the size
  // while working doesn't throw the picture away.
  function resizeCodes(codes, oldWidth, oldHeight, width, height) {
    const out = new Uint8Array(width * height);
    for (let y = 0; y < Math.min(height, oldHeight); y++) {
      for (let x = 0; x < Math.min(width, oldWidth); x++) {
        out[y * width + x] = codes[y * oldWidth + x];
      }
    }
    return out;
  }

  // Pointer events arrive far more sparsely than the cells a drag crosses -
  // move quickly and you'd get a dotted line - so a stroke joins each event
  // to the last one with a Bresenham line rather than painting single cells.
  function cellsBetween(from, to) {
    const cells = [];
    let x = from.x;
    let y = from.y;
    const dx = Math.abs(to.x - x);
    const dy = -Math.abs(to.y - y);
    const sx = x < to.x ? 1 : -1;
    const sy = y < to.y ? 1 : -1;
    let err = dx + dy;
    for (;;) {
      cells.push({ x, y });
      if (x === to.x && y === to.y) return cells;
      const e2 = 2 * err;
      if (e2 >= dy) { err += dy; x += sx; }
      if (e2 <= dx) { err += dx; y += sy; }
    }
  }

  // Paints one segment of a stroke in place. Returns whether anything
  // actually changed, so a drag within a single cell doesn't force a
  // re-render.
  function paintLine(codes, width, height, from, to, code) {
    let changed = false;
    cellsBetween(from, to).forEach(({ x, y }) => {
      if (x < 0 || y < 0 || x >= width || y >= height) return;
      const index = y * width + x;
      if (codes[index] === code) return;
      codes[index] = code;
      changed = true;
    });
    return changed;
  }

  // Mirrors AlphaSign::DotsFile#lit_chip_fraction (yellow = 2 chips,
  // red/green = 1, off = 0) so the 50% LED safety warning shows before the
  // user even hits Send, not just after serial_api rejects it.
  function chipFraction(codes) {
    let chips = 0;
    codes.forEach((c) => { chips += c === 3 ? 2 : c === 0 ? 0 : 1; });
    return chips / (codes.length * 2);
  }

  // "Fit width" zoom. Capped at 20px so a tiny icon isn't rendered
  // enormous, and floored at 2px so a full-width picture still draws
  // something when there's no room.
  function fitCellSize(available, width) {
    return Math.max(2, Math.min(20, Math.floor(available / width)));
  }

  return {
    MATCH_PALETTE, ORDER, PREVIEW_COLORS, SIGN_WIDTH, SIGN_HEIGHT,
    clampInt, nearestColorIndex, ditherToDots, naturalTargetSize,
    encodePixels, decodePixels, resizeCodes, cellsBetween, paintLine,
    chipFraction, fitCellSize
  };
});
