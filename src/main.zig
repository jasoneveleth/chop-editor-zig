const std = @import("std");
const Editor = @import("editor.zig").Editor;
const draw = @import("draw.zig");
const platform = @import("platform/web.zig");
const Key = @import("key.zig").Key;

const allocator = std.heap.page_allocator;

var editor: Editor = undefined;
var initialized = false;

export fn init(width: u32, height: u32) void {
    editor = Editor.init(allocator, width, height) catch return;
    initialized = true;
}

export fn render(time_ms: f64) void {
    if (!initialized) return;
    var dl = draw.DrawList.init(allocator);
    defer dl.deinit();
    editor.buildDrawList(&dl, time_ms) catch return;
    platform.present(&dl);
}

export fn on_key_down(raw: u32, mods: u32) void {
    if (!initialized) return;
    editor.onKeyDown(@enumFromInt(raw), mods);
}

export fn on_key_up(raw: u32, mods: u32) void {
    if (!initialized) return;
    editor.onKeyUp(@enumFromInt(raw), mods);
}

export fn on_mouse(x: f32, y: f32, button: u8, kind: u8) void {
    if (!initialized) return;
    editor.onMouse(x, y, button, kind);
}

export fn on_scroll(dx: f32, dy: f32) void {
    if (!initialized) return;
    editor.onScroll(dx, dy);
}

export fn on_resize(width: u32, height: u32) void {
    if (!initialized) return;
    editor.onResize(width, height);
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    @trap();
}
