const std = @import("std");
const editor = @import("editor.zig");
const draw = @import("draw.zig");
const platform = @import("platform/web.zig");
const keys = @import("keys.zig");

const Editor = editor.Editor;
const Key = keys.Key;

const allocator = std.heap.page_allocator;

var ed: Editor = undefined;
var initialized = false;

export fn init(width: u32, height: u32, is_dark: u32) void {
    ed = Editor.init(allocator, width, height, is_dark != 0) catch return;
    initialized = true;
}

export fn render(time_ms: f64) void {
    if (!initialized) return;
    var dl = draw.DrawList.init(allocator);
    defer dl.deinit();
    ed.buildDrawList(&dl, time_ms) catch return;
    platform.present(&dl);
}

export fn on_key_down(time_ms: f64, raw: u32, mods: u32) void {
    if (!initialized) return;
    ed.onKeyDown(time_ms, @enumFromInt(raw), mods);
}

export fn on_key_up(raw: u32, mods: u32) void {
    if (!initialized) return;
    ed.onKeyUp(@enumFromInt(raw), mods);
}

export fn on_mouse(x: f32, y: f32, button: u8, kind: u8, mods: u32) void {
    if (!initialized) return;
    ed.onMouse(x, y, button, kind, mods);
}

export fn on_scroll(time_ms: f64, dx: f32, dy: f32) void {
    if (!initialized) return;
    ed.onScroll(time_ms, dx, dy);
}

export fn on_resize(width: u32, height: u32) void {
    if (!initialized) return;
    ed.onResize(width, height);
}

export fn set_dark_mode(is_dark: u32) void {
    if (!initialized) return;
    ed.colorscheme = if (is_dark != 0) .onedark else .alabaster;
}

// Satisfy musl's CRT symbol requirement; never actually called (entry = .disabled).
export fn main() c_int { return 0; }

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    @trap();
}
