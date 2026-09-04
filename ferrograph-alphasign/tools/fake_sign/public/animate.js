"use strict";

// Turns a composed message bitmap into what the display shows at a given
// moment: pure window maths, no DOM, so it can be tested directly (see
// test/fake_sign/animate_test.js).
//
// The geometric effects - rotate, rolls, wipes, implode/explode - are
// modelled from Appendix C's descriptions and are as faithful as their
// timings allow. The decorative extended effects (twinkle, dissolve, snow)
// are impressions: the manual names them and describes their character but
// gives no pattern, so what's here is a plausible animation of the right
// shape, not a reproduction of the sign's.
(function (root, factory) {
  const api = factory();
  root.Animate = api;
  if (typeof module === "object" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  const WIDTH = 135;
  const HEIGHT = 16;

  function blank(width = WIDTH, height = HEIGHT) {
    return Array.from({ length: height }, () => new Array(width).fill(0));
  }

  // Copies the canvas onto the display with its top-left corner at
  // (offsetX, offsetY). Anything outside the display is clipped; anything
  // the canvas doesn't cover stays dark.
  function place(canvas, offsetX, offsetY, width = WIDTH, height = HEIGHT) {
    const out = blank(width, height);
    const canvasHeight = canvas.length;
    const canvasWidth = canvasHeight ? canvas[0].length : 0;
    // Whole pixels only. A fractional offset - which is what elapsed time
    // produces in practice - would index the canvas at a non-integer and
    // silently read undefined, blanking the display. An LED panel steps by
    // whole pixels anyway.
    offsetX = Math.round(offsetX);
    offsetY = Math.round(offsetY);
    for (let y = 0; y < height; y++) {
      const sourceY = y - offsetY;
      if (sourceY < 0 || sourceY >= canvasHeight) continue;
      for (let x = 0; x < width; x++) {
        const sourceX = x - offsetX;
        if (sourceX < 0 || sourceX >= canvasWidth) continue;
        out[y][x] = canvas[sourceY][sourceX];
      }
    }
    return out;
  }

  // Keeps only the pixels a predicate accepts - the basis of every wipe.
  function mask(pixels, keep) {
    return pixels.map((row, y) => row.map((value, x) => (keep(x, y) ? value : 0)));
  }

  // A deterministic shuffle, so a dissolve looks scattered but a test can
  // still assert on it. Mulberry32.
  function ordering(count, seed = 0x9e3779b9) {
    let state = seed >>> 0;
    const random = () => {
      state = (state + 0x6d2b79f5) >>> 0;
      let t = state;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
    const indices = Array.from({ length: count }, (_, i) => i);
    for (let i = count - 1; i > 0; i--) {
      const j = Math.floor(random() * (i + 1));
      [indices[i], indices[j]] = [indices[j], indices[i]];
    }
    return indices;
  }

  const dissolveCache = new Map();
  function dissolveOrder(width, height) {
    const key = `${width}x${height}`;
    if (!dissolveCache.has(key)) dissolveCache.set(key, ordering(width * height));
    return dissolveCache.get(key);
  }

  function clamp01(value) {
    return Math.min(1, Math.max(0, value));
  }

  // How long one full cycle of a frame lasts, so a player knows when to
  // move to the next file in the run sequence.
  function duration(frame, timings) {
    const canvasWidth = frame.canvas.width;
    switch (frame.motion) {
      case "rotate":
        return (canvasWidth + WIDTH) / timings.rotate_pixels_per_second;
      case "flash":
        return frame.pause;
      default:
        return frame.transition + frame.pause;
    }
  }

  // The display at `elapsed` seconds into this frame's cycle.
  function render(frame, elapsed, timings) {
    const canvas = frame.canvas.pixels;
    const canvasWidth = frame.canvas.width;
    const transition = frame.transition;
    const progress = transition > 0 ? clamp01(elapsed / transition) : 1;

    switch (frame.motion) {
      case "rotate": {
        // Enters at the right edge and travels left until fully gone.
        const travelled = elapsed * timings.rotate_pixels_per_second;
        return place(canvas, WIDTH - travelled, 0);
      }
      case "flash": {
        // Fixed display, continually flashing.
        const on = Math.floor(elapsed / (timings.flash_period_seconds / 2)) % 2 === 0;
        return on ? place(canvas, 0, 0) : blank();
      }
      case "roll_left":
        return place(canvas, Math.round(WIDTH * (1 - progress)), 0);
      case "roll_right":
        return place(canvas, Math.round(-WIDTH * (1 - progress)), 0);
      case "roll_up":
      case "scroll":
        return place(canvas, 0, Math.round(HEIGHT * (1 - progress)));
      case "roll_down":
        return place(canvas, 0, Math.round(-HEIGHT * (1 - progress)));
      case "wipe_left":
        return mask(place(canvas, 0, 0), (x) => x >= WIDTH * (1 - progress));
      case "wipe_right":
        return mask(place(canvas, 0, 0), (x) => x < WIDTH * progress);
      case "wipe_up":
        return mask(place(canvas, 0, 0), (_x, y) => y >= HEIGHT * (1 - progress));
      case "wipe_down":
        return mask(place(canvas, 0, 0), (_x, y) => y < HEIGHT * progress);
      case "implode_wipe":
        // Two halves wipe inward: revealed from both edges towards centre.
        return mask(place(canvas, 0, 0), (x) => Math.min(x, WIDTH - 1 - x) < (WIDTH / 2) * progress);
      case "explode_wipe":
        // ...and outward from the centre.
        return mask(place(canvas, 0, 0), (x) => Math.abs(x - WIDTH / 2) < (WIDTH / 2) * progress);
      case "implode_scroll":
      case "explode_scroll": {
        // Halves slide, one from each side.
        const shift = Math.round((WIDTH / 2) * (1 - progress));
        const from = frame.motion === "implode_scroll" ? shift : -shift;
        const left = mask(place(canvas, from, 0), (x) => x < WIDTH / 2);
        const right = mask(place(canvas, -from, 0), (x) => x >= WIDTH / 2);
        return left.map((row, y) => row.map((value, x) => value || right[y][x]));
      }
      case "explode_vertical": {
        // Top half scrolls up, bottom half scrolls down.
        const shift = Math.round(HEIGHT * (1 - progress));
        const top = mask(place(canvas, 0, -shift), (_x, y) => y < HEIGHT / 2);
        const bottom = mask(place(canvas, 0, shift), (_x, y) => y >= HEIGHT / 2);
        return top.map((row, y) => row.map((value, x) => value || bottom[y][x]));
      }
      case "dissolve":
      case "snow":
      case "dissolve_wipe":
      case "slide":
      case "switch":
      case "interlock_wipe":
      case "interlock_scroll":
      case "cursor_wipe": {
        // Impressions, not reproductions - see the note at the top.
        const order = dissolveOrder(WIDTH, HEIGHT);
        const revealed = Math.floor(order.length * progress);
        const visible = new Set(order.slice(0, revealed));
        return mask(place(canvas, 0, 0), (x, y) => visible.has(y * WIDTH + x));
      }
      case "twinkle": {
        // A continuous shifting dot crawl over a settled message.
        const order = dissolveOrder(WIDTH, HEIGHT);
        const phase = Math.floor(elapsed * 12) % 4;
        return mask(place(canvas, 0, 0), (x, y) => order[y * WIDTH + x] % 4 !== phase);
      }
      case "auto":
      case "hold":
      default:
        return place(canvas, 0, 0);
    }
  }

  return { WIDTH, HEIGHT, blank, place, mask, ordering, render, duration, clamp01 };
});
