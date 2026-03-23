"use strict";

const canvas = document.getElementById("c");
const ctx = canvas.getContext("2d");
const decoder = new TextDecoder("utf-8");
const encoder = new TextEncoder();

// WASM linear memory — set once the module is instantiated.
let memory;

// Clipboard cache — updated on focus and after writes.
let clipboardText = "";

// ── Canvas helpers ────────────────────────────────────────────────────────────

function unpackColor(u32) {
  // 0xRRGGBBAA
  const r = (u32 >>> 24) & 0xff;
  const g = (u32 >>> 16) & 0xff;
  const b = (u32 >>>  8) & 0xff;
  const a = (u32 >>>  0) & 0xff;
  return `rgba(${r},${g},${b},${a / 255})`;
}

function wasmStr(ptr, len) {
  return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
}

// ── JS imports (called from WASM via extern fn) ───────────────────────────────

// WASI shims — the WASM module now targets wasm32-wasi (for libc/tree-sitter),
// but we don't actually use any WASI syscalls at runtime. These stubs satisfy
// the linker's import requirements.
const wasi_snapshot_preview1 = {
  fd_write:          () => 0,
  fd_read:           () => 0,
  fd_close:          () => 0,
  fd_seek:           () => 0,
  fd_fdstat_get:         () => 0,
  fd_fdstat_set_flags:   () => 0,
  fd_prestat_get:        () => 8,  // EBADF — no preopens
  fd_prestat_dir_name: () => 0,
  environ_get:       () => 0,
  environ_sizes_get: (countPtr, bufPtr) => {
    const view = new DataView(memory.buffer);
    view.setUint32(countPtr, 0, true);
    view.setUint32(bufPtr,   0, true);
    return 0;
  },
  args_get:          () => 0,
  args_sizes_get:    (countPtr, bufPtr) => {
    const view = new DataView(memory.buffer);
    view.setUint32(countPtr, 0, true);
    view.setUint32(bufPtr,   0, true);
    return 0;
  },
  proc_exit: (code) => { throw new Error("proc_exit(" + code + ")"); },
  clock_time_get:    () => 0,
  random_get: () => 0,
};

const imports = {
  wasi_snapshot_preview1,
  env: {
    js_fill_rect(x, y, w, h, color) {
      ctx.fillStyle = unpackColor(color);
      ctx.fillRect(x, y, w, h);
    },

    js_draw_text(x, y, ptr, len, color, size) {
      ctx.fillStyle = unpackColor(color);
      ctx.font = `${size}px 'IBM Plex Mono', monospace`;
      ctx.fillText(wasmStr(ptr, len), x, y);
    },

    js_draw_cursor(x, y, w, h, color) {
      ctx.fillStyle = unpackColor(color);
      ctx.fillRect(x, y, w, h);
    },

    js_clip_rect(x, y, w, h) {
      ctx.save();
      ctx.beginPath();
      ctx.rect(x, y, w, h);
      ctx.clip();
    },

    js_clear_clip() {
      ctx.restore();
    },

    js_measure_text(ptr, len, size) {
      ctx.font = `${size}px 'IBM Plex Mono', monospace`;
      return ctx.measureText(wasmStr(ptr, len)).width;
    },

    js_panic(ptr, len) {
      throw new Error("zig panic: " + wasmStr(ptr, len));
    },

    js_log(ptr, len) {
      console.log(wasmStr(ptr, len));
    },

    js_clipboard_write(ptr, len) {
      clipboardText = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
      navigator.clipboard.writeText(clipboardText).catch(() => {});
    },

    js_clipboard_read(outPtr, maxLen) {
      const bytes = encoder.encode(clipboardText);
      const n = Math.min(bytes.length, maxLen);
      new Uint8Array(memory.buffer, outPtr, n).set(bytes.subarray(0, n));
      return n;
    },

    js_open_url(ptr, len) {
      const url = wasmStr(ptr, len);
      window.open(url, '_blank');
    },
  },
};

// ── Resize ────────────────────────────────────────────────────────────────────

function resize(wasm) {
  const dpr = window.devicePixelRatio || 1;
  const w = window.innerWidth;
  const h = window.innerHeight;
  canvas.width  = Math.round(w * dpr);
  canvas.height = Math.round(h * dpr);
  canvas.style.width  = w + "px";
  canvas.style.height = h + "px";
  ctx.scale(dpr, dpr);
  wasm.exports.on_resize(Math.round(w), Math.round(h));
}

// ── Key encoding ──────────────────────────────────────────────────────────────
// Mirrors key.zig: codepoints 0–0x10FFFF are printable chars (already
// layout/shift-resolved by e.key); 0x110000+ are special keys.

const MOD_SHIFT = 1 << 0;
const MOD_CTRL  = 1 << 1;
const MOD_ALT   = 1 << 2;
const MOD_META  = 1 << 3; // Cmd on macOS

const SPECIAL_KEYS = {
  Enter:      0x110000,
  Escape:     0x110001,
  Backspace:  0x110002,
  Tab:        0x110003,
  ArrowLeft:  0x110004,
  ArrowRight: 0x110005,
  ArrowUp:    0x110006,
  ArrowDown:  0x110007,
};

function encodeKey(e) {
  // On macOS, Alt+letter reports the alt-modified character in e.key (e.g. Alt+k → "˚").
  // Recover the base letter from e.code ("KeyK" → "k") so the Zig side sees the
  // plain codepoint with MOD_ALT set in mods.
  if (e.altKey && e.code.startsWith("Key")) {
    return e.code.slice(3).toLowerCase().codePointAt(0);
  }
  if (e.key.length === 1) return e.key.codePointAt(0);
  return SPECIAL_KEYS[e.key] ?? 0xFFFFFFFF;
}

function modsFromEvent(e) {
  return (e.shiftKey ? MOD_SHIFT : 0) |
         (e.ctrlKey  ? MOD_CTRL  : 0) |
         (e.altKey   ? MOD_ALT   : 0) |
         (e.metaKey  ? MOD_META  : 0);
}

// ── Bootstrap ─────────────────────────────────────────────────────────────────

async function main() {
  await document.fonts.ready;
  const resp = await fetch("editor.wasm");
  const { instance } = await WebAssembly.instantiateStreaming(resp, imports);
  const wasm = instance;
  memory = wasm.exports.memory;

  // Size canvas to window before init so the editor knows its dimensions.
  const dpr = window.devicePixelRatio || 1;
  canvas.width  = Math.round(window.innerWidth  * dpr);
  canvas.height = Math.round(window.innerHeight * dpr);
  canvas.style.width  = window.innerWidth  + "px";
  canvas.style.height = window.innerHeight + "px";
  ctx.scale(dpr, dpr);

  const darkMQ = window.matchMedia("(prefers-color-scheme: dark)");
  const isDark = darkMQ.matches ? 1 : 0;
  darkMQ.addEventListener("change", (e) => {
    wasm.exports.set_dark_mode(e.matches ? 1 : 0);
  });
  wasm.exports.init(
    Math.round(window.innerWidth),
    Math.round(window.innerHeight),
    isDark,
  );

  // Seed clipboard cache and keep it fresh on window focus.
  navigator.clipboard.readText().then(t => { clipboardText = t; }).catch(() => {});
  window.addEventListener("focus", () => {
    navigator.clipboard.readText().then(t => { clipboardText = t; }).catch(() => {});
  });

  // Resize
  window.addEventListener("resize", () => resize(wasm));

  // Keyboard
  window.addEventListener("keydown", (e) => {
    e.preventDefault();
    wasm.exports.on_key_down(lastFrameTs, encodeKey(e), modsFromEvent(e));
  });
  window.addEventListener("keyup", (e) => {
    wasm.exports.on_key_up(encodeKey(e), modsFromEvent(e));
  });

  // Mouse
  canvas.addEventListener("mousemove",  (e) => wasm.exports.on_mouse(e.offsetX, e.offsetY, 0, 0, 0));
  canvas.addEventListener("mousedown",  (e) => wasm.exports.on_mouse(e.offsetX, e.offsetY, e.button, 1, modsFromEvent(e)));
  canvas.addEventListener("mouseup",    (e) => wasm.exports.on_mouse(e.offsetX, e.offsetY, e.button, 2, 0));

  // Scroll
  window.addEventListener("wheel", (e) => {
    e.preventDefault();
    wasm.exports.on_scroll(lastFrameTs, e.deltaX, e.deltaY);
  }, { passive: false });

  // Render loop
  let lastFrameTs = 0;
  function frame(ts) {
    lastFrameTs = ts;
    wasm.exports.render(ts);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

main().catch(console.error);
