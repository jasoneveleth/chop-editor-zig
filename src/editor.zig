const std = @import("std");
const draw = @import("draw.zig");
const Buffer = @import("buffer.zig").Buffer;
const BufferId = @import("buffer.zig").BufferId;
const Window = @import("window.zig").Window;
const WindowId = @import("window.zig").WindowId;
const CursorSet = @import("cursor_set.zig").CursorSet;
const CursorSetId = @import("cursor_set.zig").CursorSetId;
const Cursor = @import("cursor.zig").Cursor;
const Key = @import("key.zig").Key;
const Palette = @import("palette.zig").Palette;
const Match = @import("palette.zig").Match;
const platform = @import("platform/web.zig");
const grapheme = @import("grapheme.zig");

const FILLER_TEXT = "Out of the night that covers me,\n      Black as the pit from pole to pole,\nI thank whatever gods may be\n      For my unconquerable soul.\n\nIn the fell clutch of circumstance\n      I have not winced nor cried aloud.\nUnder the bludgeonings of chance\n      My head is bloody, but unbowed.\n\nBeyond this place of wrath and tears\n      Looms but the Horror of the shade,\nAnd yet the menace of the years\n      Finds and shall find me unafraid.\n\nIt matters not how strait the gate,\n      How charged with punishments the scroll,\nI am the master of my fate,\n      I am the captain of my soul.";

// ── Cursor movement helpers ────────────────────────────────────────────────

fn cursorLeft(content: []const u8, head: usize) usize {
    return grapheme.prevGrapheme(content, head);
}

fn cursorRight(content: []const u8, head: usize) usize {
    return grapheme.nextGrapheme(content, head);
}

/// Walk graphemes on [line_start, line_end), return the byte offset whose
/// measured x-position is closest to target_x.
fn closestPosToX(content: []const u8, line_start: usize, line_end: usize, target_x: f32, font_size: f32) usize {
    var it = grapheme.GraphemeIterator{ .text = content[0..line_end], .pos = @intCast(line_start) };
    var prev_pos: usize = line_start;
    var prev_x: f32 = 0;
    while (it.next()) |_| {
        const cur_pos: usize = @as(usize, it.pos);
        const cur_x = platform.measureText(content[line_start..cur_pos], font_size);
        if (cur_x >= target_x) {
            return if (target_x - prev_x <= cur_x - target_x) prev_pos else cur_pos;
        }
        prev_pos = cur_pos;
        prev_x = cur_x;
    }
    return prev_pos;
}

fn cursorUp(content: []const u8, head: usize, col_px: f32, font_size: f32) usize {
    const ls = grapheme.lineStart(content, head);
    if (ls == 0) return head;
    const prev_le = ls - 1;
    const prev_ls = grapheme.lineStart(content, prev_le);
    return closestPosToX(content, prev_ls, prev_le, col_px, font_size);
}

fn cursorDown(content: []const u8, head: usize, col_px: f32, font_size: f32) usize {
    const le = grapheme.findChars(content, head, "\n");
    if (le >= content.len) return head;
    const next_ls = le + 1;
    const next_le = grapheme.findChars(content, next_ls, "\n");
    return closestPosToX(content, next_ls, next_le, col_px, font_size);
}

pub const Editor = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(Window),
    buffers: std.ArrayList(Buffer),
    cursor_sets: std.ArrayList(CursorSet),
    /// Maps BufferId (bit-cast to u32) → list of CursorSetIds watching that buffer.
    buffer_cursor_sets: std.AutoHashMap(u32, std.ArrayList(CursorSetId)),
    focused_window: WindowId,
    palette: Palette,
    palette_open: bool,
    last_input_ms: f64 = 0,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Editor {
        var editor = Editor{
            .allocator = allocator,
            .windows = .{},
            .buffers = .{},
            .cursor_sets = .{},
            .buffer_cursor_sets = std.AutoHashMap(u32, std.ArrayList(CursorSetId)).init(allocator),
            .focused_window = undefined,
            .palette = undefined,
            .palette_open = false,
        };

        // Main buffer + cursor set + window.
        const buf_id = try editor.createBuffer();
        editor.getBuffer(buf_id).?.insert(0, FILLER_TEXT) catch {};
        const cs_id = try editor.createCursorSet(buf_id);
        try editor.getCursorSet(cs_id).?.insert(Cursor.init(0));
        editor.focused_window = try editor.createWindow(buf_id, cs_id, width, height);

        // Palette buffer + cursor set (empty, cleared on each open).
        const pal_buf_id = try editor.createBuffer();
        const pal_cs_id = try editor.createCursorSet(pal_buf_id);
        try editor.getCursorSet(pal_cs_id).?.insert(Cursor.init(0));
        editor.palette = Palette.init(pal_buf_id, pal_cs_id);

        return editor;
    }

    pub fn deinit(self: *Editor) void {
        self.palette.deinit(self.allocator);
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

    // ── Search ────────────────────────────────────────────────────────────────

    fn openPalette(self: *Editor) !void {
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;

        // Snapshot current cursors for Escape restore.
        self.palette.saved_cursors = cs.*;

        // Clear palette buffer.
        const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
        if (pal_buf.len() > 0) self.bufferDelete(self.palette.buffer_id, 0, pal_buf.len());

        // Reset palette cursor to 0.
        const pal_cs = self.getCursorSet(self.palette.cursor_set_id) orelse return;
        pal_cs.clear();
        try pal_cs.insert(Cursor.init(0));

        self.palette.matches.clearRetainingCapacity();
        self.palette_open = true;
    }

    fn closePalette(self: *Editor, confirm: bool) void {
        self.palette_open = false;
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;

        if (confirm and self.palette.matches.items.len > 0) {
            const first = self.palette.matches.items[0];
            cs.clear();
            cs.insert(Cursor.init(first.start)) catch {};
        } else {
            cs.* = self.palette.saved_cursors;
        }

        self.palette.matches.clearRetainingCapacity();
    }

    fn updateMatches(self: *Editor) !void {
        self.palette.matches.clearRetainingCapacity();
        const win = self.getWindow(self.focused_window) orelse return;
        const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
        const main_buf = self.getBuffer(win.buffer_id) orelse return;

        const pattern = pal_buf.bytes();
        if (pattern.len == 0) return;

        const content = main_buf.bytes();
        var i: usize = 0;
        while (i + pattern.len <= content.len) {
            if (std.mem.eql(u8, content[i .. i + pattern.len], pattern)) {
                try self.palette.matches.append(self.allocator, .{ .start = i, .end = i + pattern.len });
                i += pattern.len;
            } else {
                i += 1;
            }
        }
    }

    fn handlePaletteKey(self: *Editor, key: Key, mods: u32) void {
        _ = mods;
        const pal_cs = self.getCursorSet(self.palette.cursor_set_id) orelse return;

        switch (key) {
            .escape => self.closePalette(false),
            .enter  => self.closePalette(true),

            .backspace => {
                if (pal_cs.len > 0 and pal_cs.buf[0].head > 0) {
                    self.bufferDelete(self.palette.buffer_id, pal_cs.buf[0].head - 1, 1);
                    self.updateMatches() catch {};
                }
            },

            .arrow_left => {
                if (pal_cs.len > 0 and pal_cs.buf[0].head > 0) {
                    pal_cs.buf[0].head -= 1;
                    pal_cs.buf[0].offset = 0;
                }
            },

            .arrow_right => {
                if (pal_cs.len > 0) {
                    const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
                    if (pal_cs.buf[0].head < pal_buf.len()) {
                        pal_cs.buf[0].head += 1;
                        pal_cs.buf[0].offset = 0;
                    }
                }
            },

            else => if (key.isPrintable()) {
                var encoded: [4]u8 = undefined;
                const cp: u21 = @intCast(@intFromEnum(key));
                const byte_len = std.unicode.utf8Encode(cp, &encoded) catch return;
                if (pal_cs.len > 0) {
                    self.bufferInsert(self.palette.buffer_id, pal_cs.buf[0].head, encoded[0..byte_len]) catch return;
                    self.updateMatches() catch {};
                }
            },
        }
    }

    // ── Rendering ─────────────────────────────────────────────────────────────

    pub fn buildDrawList(self: *Editor, dl: *draw.DrawList, time_ms: f64) !void {
        const cursor_visible = @mod(time_ms - self.last_input_ms, 1000) < 667;

        const win = self.getWindow(self.focused_window) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;

        const highlights: []const Match = if (self.palette_open) self.palette.matches.items else &.{};
        try win.buildDrawList(dl, buf, cs, highlights, cursor_visible);

        if (self.palette_open) try self.drawPalette(dl, win);
    }

    fn drawPalette(self: *Editor, dl: *draw.DrawList, win: *const Window) !void {
        const font_size: f32 = 14;
        const line_height = font_size * 1.4;

        const pal_w: f32 = @min(600, win.width - 80);
        const pal_h: f32 = line_height * 2;
        const pal_x: f32 = (win.width - pal_w) / 2;
        const pal_y: f32 = 24;
        const baseline = pal_y + (pal_h + font_size) / 2;
        const text_x = pal_x + 14;

        // Box background.
        try dl.fillRect(
            .{ .x = pal_x, .y = pal_y, .w = pal_w, .h = pal_h },
            draw.Color.rgb(45, 45, 45),
        );

        // "/" prompt.
        const prompt = "/";
        const prompt_w = platform.measureText(prompt, font_size);
        try dl.drawText(text_x, baseline, prompt, draw.Color.rgb(100, 100, 100), font_size);

        // Pattern text.
        const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
        const pattern = pal_buf.bytes();
        const pat_x = text_x + prompt_w + 6;
        try dl.drawText(pat_x, baseline, pattern, draw.Color.rgb(220, 220, 220), font_size);

        // Match count hint.
        if (self.palette.matches.items.len > 0) {
            var count_buf: [32]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "{d} matches", .{self.palette.matches.items.len}) catch "";
            const count_x = pal_x + pal_w - platform.measureText(count_str, font_size) - 14;
            try dl.drawText(count_x, baseline, count_str, draw.Color.rgb(100, 100, 100), font_size);
        }

        // Palette cursor.
        const pal_cs = self.getCursorSet(self.palette.cursor_set_id) orelse return;
        if (pal_cs.len > 0) {
            const cur_head = pal_cs.buf[0].head;
            const cx = pat_x + platform.measureText(pattern[0..cur_head], font_size);
            const cur_y = pal_y + (pal_h - line_height) / 2;
            try dl.fillRect(
                .{ .x = cx - 1, .y = cur_y, .w = 2, .h = line_height },
                draw.Color.rgb(0, 196, 255),
            );
        }
    }

    // ── Input ─────────────────────────────────────────────────────────────────

    const Dir = enum { left, right, up, down };

    fn move(self: *Editor, win: *Window, cs: *CursorSet, dir: Dir) void {
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const content = buf.bytes();
        for (cs.buf[0..cs.len]) |*c| {
            switch (dir) {
                .left, .right => {
                    c.head = if (dir == .left) cursorLeft(content, c.head) else cursorRight(content, c.head);
                    win.preferred_col = null;
                },
                .up, .down => {
                    const ls = grapheme.lineStart(content, c.head);
                    const col_px = win.preferred_col orelse platform.measureText(content[ls..c.head], win.font_size);
                    win.preferred_col = col_px;
                    c.head = if (dir == .up) cursorUp(content, c.head, col_px, win.font_size) else cursorDown(content, c.head, col_px, win.font_size);
                },
            }
            c.offset = 0;
        }
    }

    pub fn onKeyDown(self: *Editor, time_ms: f64, key: Key, mods: u32) void {
        self.last_input_ms = time_ms;
        if (self.palette_open) {
            self.handlePaletteKey(key, mods);
            return;
        }

        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;
        switch (win.mode) {
            .normal => switch (key) {
                .escape      => {},
                .arrow_left  => self.move(win, cs, .left),
                .arrow_right => self.move(win, cs, .right),
                .arrow_up    => self.move(win, cs, .up),
                .arrow_down  => self.move(win, cs, .down),
                else => if (key.isPrintable()) switch (@intFromEnum(key)) {
                    'h' => self.move(win, cs, .left),
                    'l' => self.move(win, cs, .right),
                    'k' => self.move(win, cs, .up),
                    'j' => self.move(win, cs, .down),
                    'i' => win.mode = .insert,
                    ':' => win.mode = .command,
                    '/' => self.openPalette() catch {},
                    else => {},
                },
            },
            .insert => switch (key) {
                .escape      => win.mode = .normal,
                .arrow_left  => self.move(win, cs, .left),
                .arrow_right => self.move(win, cs, .right),
                .arrow_up    => self.move(win, cs, .up),
                .arrow_down  => self.move(win, cs, .down),
                .backspace => {
                    win.preferred_col = null;
                    var it = cs.reverseIter();
                    while (it.next()) |cursor| {
                        if (cursor.head > 0)
                            self.bufferDelete(win.buffer_id, cursor.head - 1, 1);
                    }
                },
                .enter => {
                    win.preferred_col = null;
                    var it = cs.reverseIter();
                    while (it.next()) |cursor| {
                        self.bufferInsert(win.buffer_id, cursor.head, "\n") catch return;
                    }
                },
                else => if (key.isPrintable()) {
                    win.preferred_col = null;
                    var encoded: [4]u8 = undefined;
                    const cp: u21 = @intCast(@intFromEnum(key));
                    const byte_len = std.unicode.utf8Encode(cp, &encoded) catch return;
                    var it = cs.reverseIter();
                    while (it.next()) |cursor| {
                        self.bufferInsert(win.buffer_id, cursor.head, encoded[0..byte_len]) catch return;
                    }
                },
            },
            .command => switch (key) {
                .escape => win.mode = .normal,
                else => {},
            },
        }
    }

    pub fn onKeyUp(self: *Editor, key: Key, mods: u32) void {
        _ = self; _ = key; _ = mods;
    }

    pub fn onMouse(self: *Editor, x: f32, y: f32, button: u8, kind: u8) void {
        _ = self; _ = x; _ = y; _ = button; _ = kind;
    }

    pub fn onScroll(self: *Editor, time_ms: f64, dx: f32, dy: f32) void {
        self.last_input_ms = time_ms;
        if (self.getWindow(self.focused_window)) |win| win.onScroll(dx, dy);
    }

    pub fn onResize(self: *Editor, width: u32, height: u32) void {
        if (self.getWindow(self.focused_window)) |win| win.onResize(width, height);
    }
};
