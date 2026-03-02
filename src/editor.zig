const std = @import("std");
const draw = @import("draw.zig");
const Buffer = @import("buffer.zig").Buffer;
const BufferId = @import("buffer.zig").BufferId;
const Window = @import("window.zig").Window;
const WindowId = @import("window.zig").WindowId;

pub const Editor = struct {
    allocator: std.mem.Allocator,
    // Simple arrays for now. No generational slot system unless we need
    // frequent create/destroy of windows or buffers.
    windows: std.ArrayList(Window),
    buffers: std.ArrayList(Buffer),
    focused_window: WindowId,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Editor {
        var editor = Editor{
            .allocator = allocator,
            .windows = .{},
            .buffers = .{},
            .focused_window = undefined, // set below
        };
        const buf_id = try editor.createBuffer();
        editor.focused_window = try editor.createWindow(buf_id, width, height);
        return editor;
    }

    pub fn deinit(self: *Editor) void {
        for (self.windows.items) |*w| w.deinit();
        for (self.buffers.items) |*b| b.deinit();
        self.windows.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
    }

    pub fn createBuffer(self: *Editor) !BufferId {
        const index: u24 = @intCast(self.buffers.items.len);
        try self.buffers.append(self.allocator, Buffer.init(self.allocator));
        return BufferId{ .index = index, .generation = 0 };
    }

    pub fn createWindow(self: *Editor, buffer_id: BufferId, width: u32, height: u32) !WindowId {
        const index: u24 = @intCast(self.windows.items.len);
        try self.windows.append(self.allocator, try Window.init(self.allocator, buffer_id, width, height));
        return WindowId{ .index = index, .generation = 0 };
    }

    pub fn getWindow(self: *Editor, id: WindowId) ?*Window {
        if (id.index >= self.windows.items.len) return null;
        return &self.windows.items[id.index];
    }

    pub fn getBuffer(self: *Editor, id: BufferId) ?*Buffer {
        if (id.index >= self.buffers.items.len) return null;
        return &self.buffers.items[id.index];
    }

    pub fn buildDrawList(self: *Editor, dl: *draw.DrawList) !void {
        const win = self.getWindow(self.focused_window) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        try win.buildDrawList(dl, buf);
    }

    pub fn onKey(self: *Editor, keycode: u32, mods: u32) void {
        if (self.getWindow(self.focused_window)) |win| {
            win.onKey(keycode, mods);
        }
    }

    pub fn onChar(self: *Editor, codepoint: u32) void {
        const win = self.getWindow(self.focused_window) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        win.onChar(codepoint, buf);
    }

    pub fn onMouse(self: *Editor, x: f32, y: f32, button: u8, kind: u8) void {
        _ = self;
        _ = x;
        _ = y;
        _ = button;
        _ = kind;
        // TODO: hit-test windows, focus, cursor placement
    }

    pub fn onScroll(self: *Editor, dx: f32, dy: f32) void {
        if (self.getWindow(self.focused_window)) |win| {
            win.onScroll(dx, dy);
        }
    }

    pub fn onResize(self: *Editor, width: u32, height: u32) void {
        if (self.getWindow(self.focused_window)) |win| {
            win.onResize(width, height);
        }
    }
};
