const draw = @import("../draw.zig");
const std = @import("std");

// JS-provided drawing functions. All imported from the "env" module by default
// in freestanding WASM. The JS host must supply these in the imports object.
extern fn js_fill_rect(x: f32, y: f32, w: f32, h: f32, color: u32) void;
extern fn js_draw_text(x: f32, y: f32, ptr: [*]const u8, len: u32, color: u32, size: f32) void;
extern fn js_clip_rect(x: f32, y: f32, w: f32, h: f32) void;
extern fn js_clear_clip() void;
// Called during layout so the editor can know how wide a string will render.
// JS uses ctx.measureText() and returns the width in pixels.
extern fn js_measure_text(ptr: [*]const u8, len: u32, size: f32) f32;
extern fn js_measure_text_with_prefix(pfx_ptr: [*]const u8, pfx_len: u32, txt_ptr: [*]const u8, txt_len: u32, size: f32) f32;
// Logging
extern fn js_log(ptr: [*]const u8, len: usize) void;
extern fn js_panic(ptr: [*]const u8, len: usize) void;
extern fn js_clipboard_write(ptr: [*]const u8, len: usize) void;
extern fn js_clipboard_read(out_ptr: [*]u8, max_len: usize) usize;
extern fn js_open_url(ptr: [*]const u8, len: usize) void;

var clipboard_scratch: [65536]u8 = undefined;

pub fn readClipboard() []u8 {
    const len = js_clipboard_read(&clipboard_scratch, clipboard_scratch.len);
    return clipboard_scratch[0..len];
}

pub fn writeClipboard(text: []const u8) void {
    js_clipboard_write(text.ptr, text.len);
}

pub fn openUrl(url: []const u8) void {
    js_open_url(url.ptr, url.len);
}

pub fn panic(msg: []const u8, _: ?*@import("builtin").StackTrace, _: ?usize) noreturn {
    js_log(msg.ptr, msg.len);
    @trap();
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    js_log(s.ptr, s.len);
}

pub fn present(dl: *const draw.DrawList) void {
    for (dl.cmds.items) |cmd| {
        switch (cmd) {
            .fill_rect => |r| js_fill_rect(
                r.rect.x, r.rect.y, r.rect.w, r.rect.h,
                r.color.toU32(),
            ),
            .draw_text => |t| js_draw_text(
                t.x, t.y,
                t.text.ptr, @intCast(t.text.len),
                t.color.toU32(), t.size,
            ),
            .clip_rect => |r| js_clip_rect(r.x, r.y, r.w, r.h),
            .clear_clip => js_clear_clip(),
        }
    }
}

pub fn measureText(text: []const u8, size: f32) f32 {
    if (text.len == 0) {
        return 0;
    }
    return js_measure_text(text.ptr, @intCast(text.len), size);
}

pub fn measureTextWithPrefix(prefix: []const u8, text: []const u8, size: f32) f32 {
    if (text.len == 0) return 0;
    if (prefix.len == 0) return measureText(text, size);
    return js_measure_text_with_prefix(prefix.ptr, @intCast(prefix.len), text.ptr, @intCast(text.len), size);
}
