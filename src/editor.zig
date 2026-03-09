const std = @import("std");
const draw = @import("draw.zig");
const Buffer = @import("buffer.zig").Buffer;
const BufferId = @import("buffer.zig").BufferId;
const Window = @import("window.zig").Window;
const WindowId = @import("window.zig").WindowId;
const CursorSet = @import("cursor_set.zig").CursorSet;
const CursorSetId = @import("cursor_set.zig").CursorSetId;
const Cursor = @import("cursor.zig").Cursor;

pub const Editor = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(Window),
    buffers: std.ArrayList(Buffer),
    cursor_sets: std.ArrayList(CursorSet),
    /// Maps BufferId (bit-cast to u32) → list of CursorSetIds watching that buffer.
    buffer_cursor_sets: std.AutoHashMap(u32, std.ArrayList(CursorSetId)),
    focused_window: WindowId,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Editor {
        var editor = Editor{
            .allocator = allocator,
            .windows = .{},
            .buffers = .{},
            .cursor_sets = .{},
            .buffer_cursor_sets = std.AutoHashMap(u32, std.ArrayList(CursorSetId)).init(allocator),
            .focused_window = undefined,
        };
        const buf_id = try editor.createBuffer();
        const cs_id = try editor.createCursorSet(buf_id);
        try editor.getCursorSet(cs_id).?.insert(Cursor.init(0));
        editor.focused_window = try editor.createWindow(buf_id, cs_id, width, height);
        return editor;
    }

    pub fn deinit(self: *Editor) void {
        var it = self.buffer_cursor_sets.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.buffer_cursor_sets.deinit();
        for (self.buffers.items) |*b| b.deinit();
        self.windows.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
        self.cursor_sets.deinit(self.allocator);
    }

    pub fn createBuffer(self: *Editor) !BufferId {
        const index: u24 = @intCast(self.buffers.items.len);
        try self.buffers.append(self.allocator, Buffer.init(self.allocator));
        self.buffers.items[index].insert(0, "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it, \"and what is the use of a book,\" thought Alice \"without pictures or conversations?\"\n\nSo she was considering in her own mind (as well as she could, for the hot day made her feel very sleepy and stupid), whether the pleasure of making a daisy-chain would be worth the trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her.\n") catch {};
        return BufferId{ .index = index, .generation = 0 };
    }

    pub fn createCursorSet(self: *Editor, buffer_id: BufferId) !CursorSetId {
        const index: u24 = @intCast(self.cursor_sets.items.len);
        try self.cursor_sets.append(self.allocator, CursorSet.init(buffer_id));
        const id = CursorSetId{ .index = index, .generation = 0 };
        const key: u32 = @bitCast(buffer_id);
        const gop = try self.buffer_cursor_sets.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.append(self.allocator, id);
        return id;
    }

    pub fn createWindow(self: *Editor, buffer_id: BufferId, cursor_set_id: CursorSetId, width: u32, height: u32) !WindowId {
        const index: u24 = @intCast(self.windows.items.len);
        try self.windows.append(self.allocator, Window.init(buffer_id, cursor_set_id, width, height));
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

    pub fn getCursorSet(self: *Editor, id: CursorSetId) ?*CursorSet {
        if (id.index >= self.cursor_sets.items.len) return null;
        return &self.cursor_sets.items[id.index];
    }

    /// Insert text into a buffer and fan out cursor adjustments to all watching cursor sets.
    pub fn bufferInsert(self: *Editor, buffer_id: BufferId, pos: usize, text: []const u8) !void {
        const buf = self.getBuffer(buffer_id) orelse return;
        try buf.insert(pos, text);
        const key: u32 = @bitCast(buffer_id);
        if (self.buffer_cursor_sets.get(key)) |ids| {
            for (ids.items) |cs_id| {
                if (self.getCursorSet(cs_id)) |cs| cs.adjustForInsert(pos, text.len);
            }
        }
    }

    /// Delete from a buffer and fan out cursor adjustments to all watching cursor sets.
    pub fn bufferDelete(self: *Editor, buffer_id: BufferId, pos: usize, len: usize) void {
        const buf = self.getBuffer(buffer_id) orelse return;
        buf.delete(pos, len);
        const key: u32 = @bitCast(buffer_id);
        if (self.buffer_cursor_sets.get(key)) |ids| {
            for (ids.items) |cs_id| {
                if (self.getCursorSet(cs_id)) |cs| cs.adjustForDelete(pos, len);
            }
        }
    }

    pub fn buildDrawList(self: *Editor, dl: *draw.DrawList) !void {
        const win = self.getWindow(self.focused_window) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;
        try win.buildDrawList(dl, buf, cs);
    }

    pub fn onKey(self: *Editor, keycode: u32, mods: u32) void {
        if (self.getWindow(self.focused_window)) |win| win.onKey(keycode, mods);
    }

    pub fn onChar(self: *Editor, codepoint: u32) void {
        const win = self.getWindow(self.focused_window) orelse return;
        if (win.mode != .insert) return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;

        var encoded: [4]u8 = undefined;
        const byte_len = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch return;

        // Iterate in reverse so earlier cursor positions aren't shifted by later insertions.
        var it = cs.reverseIter();
        while (it.next()) |cursor| {
            self.bufferInsert(win.buffer_id, cursor.head, encoded[0..byte_len]) catch return;
        }
    }

    pub fn onMouse(self: *Editor, x: f32, y: f32, button: u8, kind: u8) void {
        _ = self; _ = x; _ = y; _ = button; _ = kind;
    }

    pub fn onScroll(self: *Editor, dx: f32, dy: f32) void {
        if (self.getWindow(self.focused_window)) |win| win.onScroll(dx, dy);
    }

    pub fn onResize(self: *Editor, width: u32, height: u32) void {
        if (self.getWindow(self.focused_window)) |win| win.onResize(width, height);
    }
};
