const std = @import("std");
const draw = @import("draw.zig");
const Buffer = @import("buffer.zig").Buffer;
const BufferId = @import("buffer.zig").BufferId;
const Window = @import("window.zig").Window;
const WindowId = @import("window.zig").WindowId;
const PendingState = @import("window.zig").PendingState;
const CursorSet = @import("cursor_set.zig").CursorSet;
const CursorSetId = @import("cursor_set.zig").CursorSetId;
const Cursor = @import("cursor.zig").Cursor;
const Key = @import("key.zig").Key;
const MOD_CTRL = @import("key.zig").MOD_CTRL;
const MOD_SHIFT = @import("key.zig").MOD_SHIFT;
const MOD_ALT = @import("key.zig").MOD_ALT;
const Palette = @import("palette.zig").Palette;
const Match = @import("palette.zig").Match;
const PaletteIntent = @import("palette.zig").PaletteIntent;
const platform = @import("platform/web.zig");
const grapheme = @import("grapheme.zig");

const FILLER_TEXT = "Out of the night that covers me,\n      Black as the pit from pole to pole,\nI thank whatever gods may be\n      For my unconquerable soul.\n\nIn the fell clutch of circumstance\n      I have not winced nor cried aloud.\nUnder the bludgeonings of chance\n      My head is bloody, but unbowed.\n\nBeyond this place of wrath and tears\n      Looms but the Horror of the shade,\nAnd yet the menace of the years\n      Finds and shall find me unafraid.\n\nIt matters not how strait the gate,\n      How charged with punishments the scroll,\nI am the master of my fate,\n      I am the captain of my soul.";

// ── Cursor movement helpers ────────────────────────────────────────────────

/// Convert a click position to a buffer byte offset.
fn posFromPoint(win: *const Window, content: []const u8, click_x: f32, click_y: f32) usize {
    const line_height = win.font_size * 1.4;
    const gutter_width: f32 = 8;
    const line_idx: usize = @intFromFloat(@floor(@max(0.0, (click_y + win.scroll_y) / line_height)));
    var current_line: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        const at_end = i == content.len;
        const at_nl = !at_end and content[i] == '\n';
        if (at_nl or at_end) {
            if (current_line == line_idx)
                return closestPosToX(content, line_start, i, click_x - gutter_width, win.font_size);
            line_start = i + 1;
            current_line += 1;
        }
    }
    return content.len;
}

fn cursorLeft(content: []const u8, head: usize) usize {
    return grapheme.prevGrapheme(content, head);
}

fn cursorRight(content: []const u8, head: usize) usize {
    return grapheme.nextGrapheme(content, head);
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isSTNL(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn wordNext(content: []const u8, pos: usize) usize {
    var i = pos;
    if (i >= content.len) return content.len;
    if (isWordChar(content[i])) {
        while (i < content.len and isWordChar(content[i])) i += 1;
    } else if (!isSTNL(content[i])) {
        while (i < content.len and !isWordChar(content[i]) and !isSTNL(content[i])) i += 1;
    }
    while (i < content.len and isSTNL(content[i])) i += 1;
    return i;
}

fn wordPrev(content: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and isSTNL(content[i - 1])) i -= 1;
    if (i == 0) return 0;
    if (isWordChar(content[i - 1])) {
        while (i > 0 and isWordChar(content[i - 1])) i -= 1;
    } else {
        while (i > 0 and !isWordChar(content[i - 1]) and !isSTNL(content[i - 1])) i -= 1;
    }
    return i;
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

/// First match with start >= from; wraps to first if none found.
fn findNextMatchFrom(matches: []const Match, from: usize) ?Match {
    for (matches) |m| if (m.start >= from) return m;
    if (matches.len > 0) return matches[0];
    return null;
}

/// Last match with end <= from; wraps to last if none found.
fn findPrevMatchFrom(matches: []const Match, from: usize) ?Match {
    var i = matches.len;
    while (i > 0) {
        i -= 1;
        if (matches[i].end <= from) return matches[i];
    }
    if (matches.len > 0) return matches[matches.len - 1];
    return null;
}

fn sneakForward(content: []const u8, from: usize, c1: u8, c2: u8) ?usize {
    var i = from + 1;
    while (i + 1 < content.len) : (i += 1) {
        if (content[i] == c1 and content[i + 1] == c2) return i;
    }
    return null;
}

fn sneakBackward(content: []const u8, from: usize, c1: u8, c2: u8) ?usize {
    var i = from;
    while (i > 0) {
        i -= 1;
        if (i + 1 < content.len and content[i] == c1 and content[i + 1] == c2) return i;
    }
    return null;
}

fn quoteBounds(content: []const u8, pos: usize, quote: u8) ?Bounds {
    // search backward for opening quote
    var s = pos;
    while (true) {
        if (s == 0) return null;
        s -= 1;
        if (content[s] == quote) break;
    }
    // search forward for closing quote
    var e = pos;
    while (e < content.len and content[e] != quote) e += 1;
    if (e >= content.len) return null;
    return .{ .start = s, .end = e };
}

fn parenBounds(content: []const u8, pos: usize, open: u8, close: u8) ?Bounds {
    // search backward for opening paren (tracking nesting)
    var depth: usize = 0;
    var s = pos;
    while (true) {
        if (s == 0) return null;
        s -= 1;
        if (content[s] == close) depth += 1
        else if (content[s] == open) {
            if (depth == 0) break;
            depth -= 1;
        }
    }
    // search forward for matching closing paren
    depth = 0;
    var e = pos;
    while (e < content.len) : (e += 1) {
        if (content[e] == open) depth += 1
        else if (content[e] == close) {
            if (depth == 0) break;
            depth -= 1;
        }
    }
    if (e >= content.len) return null;
    return .{ .start = s, .end = e };
}

fn wordBoundsAt(content: []const u8, pos: usize) ?Bounds {
    if (pos >= content.len or !isWordChar(content[pos])) return null;
    var s = pos;
    while (s > 0 and isWordChar(content[s - 1])) s -= 1;
    var e = pos + 1;
    while (e < content.len and isWordChar(content[e])) e += 1;
    return .{ .start = s, .end = e };
}

const Bounds = struct { start: usize, end: usize };

fn surroundPair(ch: u8) struct { open: u8, close: u8 } {
    return switch (ch) {
        '(', ')' => .{ .open = '(', .close = ')' },
        '[', ']' => .{ .open = '[', .close = ']' },
        '{', '}' => .{ .open = '{', .close = '}' },
        '<', '>' => .{ .open = '<', .close = '>' },
        else     => .{ .open = ch,  .close = ch  },
    };
}

fn surroundBounds(content: []const u8, pos: usize, ch: u8) ?Bounds {
    return switch (ch) {
        '(', ')' => parenBounds(content, pos, '(', ')'),
        '[', ']' => parenBounds(content, pos, '[', ']'),
        '{', '}' => parenBounds(content, pos, '{', '}'),
        '<', '>' => parenBounds(content, pos, '<', '>'),
        else     => quoteBounds(content, pos, ch),
    };
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
    last_input_ms: f64 = 0,
    dark_mode: bool = true,
    drag_anchor: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, dark_mode: bool) !Editor {
        var editor = Editor{
            .allocator = allocator,
            .windows = .{},
            .buffers = .{},
            .cursor_sets = .{},
            .buffer_cursor_sets = std.AutoHashMap(u32, std.ArrayList(CursorSetId)).init(allocator),
            .focused_window = undefined,
            .palette = undefined,
            .dark_mode = dark_mode,
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
        if (@as(u32, @bitCast(buffer_id)) != @as(u32, @bitCast(self.palette.buffer_id)))
            self.palette.matches_stale = true;
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
        if (@as(u32, @bitCast(buffer_id)) != @as(u32, @bitCast(self.palette.buffer_id)))
            self.palette.matches_stale = true;
    }

    // ── Search ────────────────────────────────────────────────────────────────

    fn openPalette(self: *Editor, intent: PaletteIntent) !void {
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;

        self.palette.intent = intent;
        self.palette.saved_cursors = cs.*;

        const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
        if (pal_buf.len() > 0) self.bufferDelete(self.palette.buffer_id, 0, pal_buf.len());

        const pal_cs = self.getCursorSet(self.palette.cursor_set_id) orelse return;
        pal_cs.clear();
        try pal_cs.insert(Cursor.init(0));

        self.palette.matches.clearRetainingCapacity();
        win.mode = .command;

        // Pre-populate with selection text if there's a single selection.
        if (cs.len == 1 and cs.items[0].isSelection()) {
            const main_buf = self.getBuffer(win.buffer_id) orelse return;
            const c = cs.items[0];
            const selected = main_buf.bytes()[c.start()..c.end()];
            pal_buf.insert(0, selected) catch {};
            pal_cs.items[0].head = selected.len;
            pal_cs.items[0].anchor = selected.len;
            self.updateMatches() catch {};
        }
    }

    fn openPaletteForSplit(self: *Editor, complement: bool) !void {
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;
        if (!cs.hasSelection()) return;

        self.palette.intent = if (complement) .split_complement else .split;
        self.palette.saved_cursors = cs.*;

        const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
        if (pal_buf.len() > 0) self.bufferDelete(self.palette.buffer_id, 0, pal_buf.len());

        const pal_cs = self.getCursorSet(self.palette.cursor_set_id) orelse return;
        pal_cs.clear();
        try pal_cs.insert(Cursor.init(0));

        self.palette.matches.clearRetainingCapacity();
        win.mode = .command;
    }

    fn applySplit(self: *Editor) void {
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const content = buf.bytes();
        const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
        const typed = pal_buf.bytes();
        const pattern: []const u8 = if (typed.len == 0) "\n" else typed;

        const saved = self.palette.saved_cursors;
        cs.clear();

        for (saved.items[0..saved.len]) |cursor| {
            if (!cursor.isSelection()) continue;
            const sel_start = cursor.start();
            const sel_end   = cursor.end();
            var i: usize = sel_start;
            while (i + pattern.len <= sel_end) {
                if (std.mem.eql(u8, content[i .. i + pattern.len], pattern)) {
                    cs.insert(.{ .anchor = i, .head = i + pattern.len }) catch break;
                    i += pattern.len;
                } else {
                    i += 1;
                }
            }
        }

        if (cs.len == 0) cs.* = saved;
    }

    fn applySplitComplement(self: *Editor) void {
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const content = buf.bytes();
        const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
        const typed = pal_buf.bytes();
        const pattern: []const u8 = if (typed.len == 0) "\n" else typed;

        const saved = self.palette.saved_cursors;
        cs.clear();

        for (saved.items[0..saved.len]) |cursor| {
            if (!cursor.isSelection()) continue;
            const sel_start = cursor.start();
            const sel_end   = cursor.end();
            var gap_start: usize = sel_start;
            var i: usize = sel_start;
            while (i + pattern.len <= sel_end) {
                if (std.mem.eql(u8, content[i .. i + pattern.len], pattern)) {
                    if (gap_start < i)
                        cs.insert(.{ .anchor = gap_start, .head = i }) catch break;
                    i += pattern.len;
                    gap_start = i;
                } else {
                    i += 1;
                }
            }
            if (gap_start < sel_end)
                cs.insert(.{ .anchor = gap_start, .head = sel_end }) catch {};
        }

        if (cs.len == 0) cs.* = saved;
    }

    fn openPaletteForFilter(self: *Editor, keep: bool) !void {
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;
        if (!cs.hasSelection()) return;

        self.palette.intent = if (keep) .filter_keep else .filter_drop;
        self.palette.saved_cursors = cs.*;

        const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
        if (pal_buf.len() > 0) self.bufferDelete(self.palette.buffer_id, 0, pal_buf.len());

        const pal_cs = self.getCursorSet(self.palette.cursor_set_id) orelse return;
        pal_cs.clear();
        try pal_cs.insert(Cursor.init(0));

        self.palette.matches.clearRetainingCapacity();
        win.mode = .command;
    }

    fn applyFilter(self: *Editor, keep: bool) void {
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const content = buf.bytes();
        const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
        const pattern = pal_buf.bytes();

        const saved = self.palette.saved_cursors;
        cs.clear();

        for (saved.items[0..saved.len]) |cursor| {
            if (!cursor.isSelection()) continue;
            const sel_start = cursor.start();
            const sel_end   = cursor.end();
            const sel_text  = content[sel_start..sel_end];
            const matches = if (pattern.len == 0) false else std.mem.indexOf(u8, sel_text, pattern) != null;
            const include = if (keep) matches else !matches;
            if (include) cs.insert(cursor) catch break;
        }

        if (cs.len == 0) cs.* = saved;
    }

    fn closePalette(self: *Editor, confirm: bool) void {
        const win = self.getWindow(self.focused_window) orelse return;
        win.mode = .normal;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;

        if (confirm) {
            switch (self.palette.intent) {
                .search_forward, .search_backward => {
                    if (self.palette.matches.items.len > 0) {
                        const saved_head = if (self.palette.saved_cursors.len > 0) self.palette.saved_cursors.items[0].head else 0;
                        const m = if (self.palette.intent == .search_forward)
                            findNextMatchFrom(self.palette.matches.items, saved_head) orelse self.palette.matches.items[0]
                        else
                            findPrevMatchFrom(self.palette.matches.items, saved_head) orelse self.palette.matches.items[self.palette.matches.items.len - 1];
                        cs.clear();
                        cs.insert(.{ .head = m.end, .anchor = m.start }) catch {};
                        // Keep matches alive for n/p/N/P navigation.
                    } else {
                        cs.* = self.palette.saved_cursors;
                        self.palette.matches.clearRetainingCapacity();
                    }
                },
                .split => {
                    self.applySplit();
                    self.palette.matches.clearRetainingCapacity();
                    self.palette.intent = .search_forward;
                },
                .split_complement => {
                    self.applySplitComplement();
                    self.palette.matches.clearRetainingCapacity();
                    self.palette.intent = .search_forward;
                },
                .filter_keep => {
                    self.applyFilter(true);
                    self.palette.matches.clearRetainingCapacity();
                    self.palette.intent = .search_forward;
                },
                .filter_drop => {
                    self.applyFilter(false);
                    self.palette.matches.clearRetainingCapacity();
                    self.palette.intent = .search_forward;
                },
            }
        } else {
            cs.* = self.palette.saved_cursors;
            self.palette.matches.clearRetainingCapacity();
            self.palette.intent = .search_forward;
        }
    }

    fn requireFreshMatches(self: *Editor) void {
        if (self.palette.matches_stale) {
            self.updateMatches() catch {};
        }
    }

    fn updateMatches(self: *Editor) !void {
        self.palette.matches_stale = false;
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

    // ── Rendering ─────────────────────────────────────────────────────────────

    pub fn buildDrawList(self: *Editor, dl: *draw.DrawList, time_ms: f64) !void {
        const cursor_visible = @mod(time_ms - self.last_input_ms, 1000) < 667;

        const win = self.getWindow(self.focused_window) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;

        const highlights: []const Match = if (win.mode == .command) self.palette.matches.items else &.{};
        try win.buildDrawList(dl, buf, cs, highlights, cursor_visible, self.dark_mode);

        if (win.mode == .command) try self.drawPalette(dl, win, self.dark_mode);
    }

    fn drawPalette(self: *Editor, dl: *draw.DrawList, win: *const Window, dark_mode: bool) !void {
        const font_size: f32 = 14;
        const line_height = font_size * 1.4;

        const pal_w: f32 = @min(600, @max(win.width - 80, 800));
        const pal_h: f32 = line_height * 1.5;
        const pal_x: f32 = (win.width - pal_w) / 2;
        const pal_y: f32 = 24;
        const baseline = pal_y + pal_h / 2 + font_size / 3; // should come from font metrics, but eyeballing for now
        const text_x = pal_x + 14;

        const pal_bg = if (dark_mode) draw.Color.rgb(45, 45, 45) else draw.Color.rgb(220, 220, 220);
        const pal_dim = if (dark_mode) draw.Color.rgb(100, 100, 100) else draw.Color.rgb(130, 130, 130);
        const pal_text = if (dark_mode) draw.Color.rgb(220, 220, 220) else draw.Color.rgb(27, 27, 27);

        // Box background.
        try dl.fillRect(
            .{ .x = pal_x, .y = pal_y, .w = pal_w, .h = pal_h },
            pal_bg,
        );

        // "/" or "?" prompt.
        const prompt = switch (self.palette.intent) {
            .search_forward   => "/",
            .search_backward  => "?",
            .split            => "s/",
            .split_complement => "S/",
            .filter_keep      => "v/",
            .filter_drop      => "V/",
        };
        const prompt_w = platform.measureText(prompt, font_size);
        try dl.drawText(text_x, baseline, prompt, pal_dim, font_size);

        // Pattern text.
        const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
        const pattern = pal_buf.bytes();
        const pat_x = text_x + prompt_w + 6;
        try dl.drawText(pat_x, baseline, pattern, pal_text, font_size);

        // Match count hint.
        if (self.palette.matches.items.len > 0) {
            var count_buf: [32]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "{d} matches", .{self.palette.matches.items.len}) catch "";
            const count_x = pal_x + pal_w - platform.measureText(count_str, font_size) - 14;
            try dl.drawText(count_x, baseline, count_str, pal_dim, font_size);
        }

        // Palette cursor.
        const pal_cs = self.getCursorSet(self.palette.cursor_set_id) orelse return;
        if (pal_cs.len > 0) {
            const cur_head = pal_cs.items[0].head;
            const cx = pat_x + platform.measureText(pattern[0..cur_head], font_size);
            const cur_y = pal_y + (pal_h - line_height) / 2;
            try dl.fillRect(
                .{ .x = cx - 1, .y = cur_y, .w = 2, .h = line_height },
                draw.Color.rgb(0, 196, 255),
            );
        }
    }

    // ── Input ─────────────────────────────────────────────────────────────────

    /// Insert text for each cursor independently.
    /// Uses strict `> pos` adjustment so overlapping cursors separate rather than
    /// all being bumped to the same post-insertion position.
    fn insertAtCursors(self: *Editor, win: *Window, cs: *CursorSet, text: []const u8) void {
        const buf_obj = self.getBuffer(win.buffer_id) orelse return;
        var idx = cs.len;
        while (idx > 0) {
            idx -= 1;
            const pos = cs.items[idx].head;
            buf_obj.insert(pos, text) catch continue;
            cs.items[idx].head = pos + (idx + 1) * text.len;
            cs.items[idx].anchor = cs.items[idx].head;
        }
    }

    const Dir = enum { left, right, up, down };

    fn deleteSelections(self: *Editor, win: *Window, cs: *CursorSet) void {
        var it = cs.reverseIter();
        while (it.next()) |cursor| {
            if (cursor.isSelection())
                self.bufferDelete(win.buffer_id, cursor.start(), cursor.end() - cursor.start());
        }
    }

    fn extendSelection(self: *Editor, win: *Window, cs: *CursorSet, dir: Dir) void {
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const content = buf.bytes();
        win.preferred_col = null;
        for (cs.items[0..cs.len]) |*c| {
            c.head = if (dir == .left) cursorLeft(content, c.head) else cursorRight(content, c.head);
        }
    }

    fn yank(self: *Editor, win: *Window, cs: *CursorSet) void {
        if (cs.len == 0) return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const content = buf.bytes();
        const c = cs.items[0];
        if (c.isSelection()) {
            platform.writeClipboard(content[c.start()..c.end()]);
        } else {
            const ls = grapheme.lineStart(content, c.head);
            const le = grapheme.findChars(content, c.head, "\n");
            const line_end = if (le < content.len) le + 1 else content.len;
            platform.writeClipboard(content[ls..line_end]);
        }
    }

    fn cut(self: *Editor, win: *Window, cs: *CursorSet) void {
        if (cs.len == 0) return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const content = buf.bytes();
        const c = cs.items[0];
        if (c.isSelection()) {
            platform.writeClipboard(content[c.start()..c.end()]);
            self.deleteSelections(win, cs);
            cs.clearSelections();
        } else {
            const ls = grapheme.lineStart(content, c.head);
            const le = grapheme.findChars(content, c.head, "\n");
            const line_end = if (le < content.len) le + 1 else content.len;
            platform.writeClipboard(content[ls..line_end]);
            self.bufferDelete(win.buffer_id, ls, line_end - ls);
        }
    }

    fn paste(self: *Editor, win: *Window, cs: *CursorSet) void {
        cs.clearSelections();
        const clip = platform.readClipboard();
        if (clip.len > 0) self.insertAtCursors(win, cs, clip);
    }

    fn move(self: *Editor, win: *Window, cs: *CursorSet, dir: Dir) void {
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const content = buf.bytes();
        for (cs.items[0..cs.len]) |*c| {
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
            c.anchor = c.head;
        }
    }

    fn execSneak(self: *Editor, win: *Window, cs: *CursorSet, c1: u8, c2: u8, forward: bool) void {
        if (c1 == 0) return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const content = buf.bytes();
        for (cs.items[0..cs.len]) |*c| {
            const result = if (forward)
                sneakForward(content, c.head, c1, c2)
            else
                sneakBackward(content, c.head, c1, c2);
            if (result) |pos| {
                c.head = pos;
                c.anchor = pos;
            }
        }
        win.preferred_col = null;
    }

    pub fn onKeyDown(self: *Editor, time_ms: f64, key: Key, mods: u32) void {
        self.last_input_ms = time_ms;
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;
        switch (win.mode) {
            .normal => switch (key) {
                .escape => { win.pending = .none; },
                .arrow_left => self.move(win, cs, .left),
                .arrow_right => self.move(win, cs, .right),
                .arrow_up => self.move(win, cs, .up),
                .arrow_down => self.move(win, cs, .down),
                .backspace => {
                    win.preferred_col = null;
                    const buf = self.getBuffer(win.buffer_id) orelse return;
                    const content = buf.bytes();
                    if (mods & MOD_SHIFT != 0) {
                        // delete char after cursor
                        var it = cs.reverseIter();
                        while (it.next()) |cursor| {
                            const next = cursorRight(content, cursor.head);
                            if (next > cursor.head)
                                self.bufferDelete(win.buffer_id, cursor.head, next - cursor.head);
                        }
                    } else {
                        // delete char before cursor
                        var it = cs.reverseIter();
                        while (it.next()) |cursor| {
                            const prev = cursorLeft(content, cursor.head);
                            if (prev < cursor.head)
                                self.bufferDelete(win.buffer_id, prev, cursor.head - prev);
                        }
                    }
                },
                else => if (key.isPrintable()) {
                    if (win.pending != .none) {
                        const prev_pending = win.pending;
                        win.pending = .none;
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        const content = buf.bytes();
                        switch (prev_pending) {
                            .none => unreachable,
                            .ms => {
                                const pair = surroundPair(@intCast(@intFromEnum(key)));
                                var idx = cs.len;
                                while (idx > 0) {
                                    idx -= 1;
                                    const c = &cs.items[idx];
                                    const s = c.start();
                                    const e = c.end();
                                    self.bufferInsert(win.buffer_id, e, &[_]u8{pair.close}) catch continue;
                                    self.bufferInsert(win.buffer_id, s, &[_]u8{pair.open}) catch continue;
                                }
                                win.preferred_col = null;
                            },
                            .md => {
                                const ch: u8 = @intCast(@intFromEnum(key));
                                var idx = cs.len;
                                while (idx > 0) {
                                    idx -= 1;
                                    const c = &cs.items[idx];
                                    if (surroundBounds(content, c.head, ch)) |b| {
                                        self.bufferDelete(win.buffer_id, b.end, 1);
                                        self.bufferDelete(win.buffer_id, b.start, 1);
                                        c.head = b.start;
                                        c.anchor = b.start;
                                    }
                                }
                                win.preferred_col = null;
                            },
                            .mr1 => {
                                win.pending = .{ .mr2 = @intCast(@intFromEnum(key)) };
                            },
                            .mr2 => |char1| {
                                const char2: u8 = @intCast(@intFromEnum(key));
                                const pair2 = surroundPair(char2);
                                var idx = cs.len;
                                while (idx > 0) {
                                    idx -= 1;
                                    const c = &cs.items[idx];
                                    if (surroundBounds(content, c.head, char1)) |b| {
                                        self.bufferDelete(win.buffer_id, b.end, 1);
                                        self.bufferInsert(win.buffer_id, b.end, &[_]u8{pair2.close}) catch {};
                                        self.bufferDelete(win.buffer_id, b.start, 1);
                                        self.bufferInsert(win.buffer_id, b.start, &[_]u8{pair2.open}) catch {};
                                    }
                                }
                                win.preferred_col = null;
                            },
                            .rl => {
                                const ch: u8 = @intCast(@intFromEnum(key));
                                var idx = cs.len;
                                while (idx > 0) {
                                    idx -= 1;
                                    const c = &cs.items[idx];
                                    const prev = cursorLeft(content, c.head);
                                    if (prev < c.head) {
                                        self.bufferDelete(win.buffer_id, prev, c.head - prev);
                                        self.bufferInsert(win.buffer_id, prev, &[_]u8{ch}) catch {};
                                    }
                                }
                                win.preferred_col = null;
                            },
                            .rr => {
                                const ch: u8 = @intCast(@intFromEnum(key));
                                var idx = cs.len;
                                while (idx > 0) {
                                    idx -= 1;
                                    const c = &cs.items[idx];
                                    const next = cursorRight(content, c.head);
                                    if (next > c.head) {
                                        self.bufferInsert(win.buffer_id, next, &[_]u8{ch}) catch {};
                                        self.bufferDelete(win.buffer_id, c.head, next - c.head);
                                    }
                                }
                                win.preferred_col = null;
                            },
                            .sf1 => |forward| {
                                win.pending = .{ .sf2 = .{ .forward = forward, .c1 = @intCast(@intFromEnum(key)) } };
                            },
                            .sf2 => |state| {
                                const c2: u8 = @intCast(@intFromEnum(key));
                                win.sneak_c1 = state.c1;
                                win.sneak_c2 = c2;
                                win.sneak_forward = state.forward;
                                self.execSneak(win, cs, state.c1, c2, state.forward);
                            },
                            .prefix => |pending| switch (pending) {
                            'g' => switch (@intFromEnum(key)) {
                                'h' => {
                                    for (cs.items[0..cs.len]) |*c| {
                                        c.head = grapheme.lineStart(content, c.head);
                                        c.anchor = c.head;
                                    }
                                    win.preferred_col = null;
                                },
                                'l' => {
                                    for (cs.items[0..cs.len]) |*c| {
                                        c.head = grapheme.findChars(content, c.head, "\n");
                                        c.anchor = c.head;
                                    }
                                    win.preferred_col = null;
                                },
                                'k' => {
                                    const first_line_end = grapheme.findChars(content, 0, "\n");
                                    for (cs.items[0..cs.len]) |*c| {
                                        const ls = grapheme.lineStart(content, c.head);
                                        const col_px = win.preferred_col orelse platform.measureText(content[ls..c.head], win.font_size);
                                        win.preferred_col = col_px;
                                        c.head = closestPosToX(content, 0, first_line_end, col_px, win.font_size);
                                        c.anchor = c.head;
                                    }
                                },
                                'j' => {
                                    var last_ls: usize = 0;
                                    for (content, 0..) |ch, i| {
                                        if (ch == '\n') last_ls = i + 1;
                                    }
                                    for (cs.items[0..cs.len]) |*c| {
                                        const ls = grapheme.lineStart(content, c.head);
                                        const col_px = win.preferred_col orelse platform.measureText(content[ls..c.head], win.font_size);
                                        win.preferred_col = col_px;
                                        c.head = closestPosToX(content, last_ls, content.len, col_px, win.font_size);
                                        c.anchor = c.head;
                                    }
                                },
                                else => {},
                            },
                            'a' => switch (@intFromEnum(key)) {
                                'w' => {
                                    for (cs.items[0..cs.len]) |*c| {
                                        if (wordBoundsAt(content, c.head)) |wb| {
                                            c.anchor = wb.start;
                                            c.head = wb.end;
                                        }
                                    }
                                    win.preferred_col = null;
                                },
                                '\'' => {
                                    for (cs.items[0..cs.len]) |*c| {
                                        if (quoteBounds(content, c.head, '\'')) |qb| {
                                            c.anchor = qb.start + 1;
                                            c.head = qb.end;
                                        }
                                    }
                                    win.preferred_col = null;
                                },
                                '(', ')' => {
                                    for (cs.items[0..cs.len]) |*c| {
                                        if (parenBounds(content, c.head, '(', ')')) |pb| {
                                            c.anchor = pb.start + 1;
                                            c.head = pb.end;
                                        }
                                    }
                                    win.preferred_col = null;
                                },
                                'p' => {
                                    for (cs.items[0..cs.len]) |*c| {
                                        // seek backward past non-blank lines to paragraph start
                                        var s = grapheme.lineStart(content, c.head);
                                        while (s > 0) {
                                            const prev_le = s - 1;
                                            const prev_ls = grapheme.lineStart(content, prev_le);
                                            if (prev_ls == prev_le) break; // blank line
                                            s = prev_ls;
                                        }
                                        // seek forward past non-blank lines to paragraph end
                                        var e = c.head;
                                        while (e < content.len) {
                                            const le = grapheme.findChars(content, e, "\n");
                                            if (le == grapheme.lineStart(content, e)) break; // blank line
                                            e = if (le < content.len) le + 1 else content.len;
                                        }
                                        c.anchor = s;
                                        c.head = e;
                                    }
                                    win.preferred_col = null;
                                },
                                'e' => {
                                    if (cs.len > 0) {
                                        cs.items[0].anchor = 0;
                                        cs.items[0].head = content.len;
                                        cs.len = 1;
                                    }
                                    win.preferred_col = null;
                                },
                                else => {},
                            },
                            'A' => switch (@intFromEnum(key)) {
                                '\'' => {
                                    for (cs.items[0..cs.len]) |*c| {
                                        if (quoteBounds(content, c.head, '\'')) |qb| {
                                            c.anchor = qb.start;
                                            c.head = qb.end + 1;
                                        }
                                    }
                                    win.preferred_col = null;
                                },
                                else => {},
                            },
                            'c' => switch (@intFromEnum(key)) {
                                'd' => {
                                    if (cs.len > 1) cs.len = 1;
                                },
                                'v' => {
                                    for (cs.items[0..cs.len]) |*c| {
                                        c.anchor = c.head;
                                    }
                                },
                                'c' => {
                                    for (cs.items[0..cs.len]) |*c| {
                                        const tmp = c.head;
                                        c.head = c.anchor;
                                        c.anchor = tmp;
                                    }
                                },
                                'C' => {
                                    for (cs.items[0..cs.len]) |*c| {
                                        if (c.head > c.anchor) {
                                            const tmp = c.head;
                                            c.head = c.anchor;
                                            c.anchor = tmp;
                                        }
                                    }
                                },
                                'j' => {
                                    if (cs.len == 0) return;
                                    const last = cs.items[cs.len - 1];
                                    const ls = grapheme.lineStart(content, last.head);
                                    const col_px = win.preferred_col orelse platform.measureText(content[ls..last.head], win.font_size);
                                    win.preferred_col = col_px;
                                    const new_head = cursorDown(content, last.head, col_px, win.font_size);
                                    if (new_head != last.head) {
                                        cs.insert(.{ .head = new_head, .anchor = new_head }) catch {};
                                    }
                                },
                                'k' => {
                                    if (cs.len == 0) return;
                                    const first = cs.items[0];
                                    const ls = grapheme.lineStart(content, first.head);
                                    const col_px = win.preferred_col orelse platform.measureText(content[ls..first.head], win.font_size);
                                    win.preferred_col = col_px;
                                    const new_head = cursorUp(content, first.head, col_px, win.font_size);
                                    if (new_head != first.head) {
                                        cs.insert(.{ .head = new_head, .anchor = new_head }) catch {};
                                    }
                                },
                                else => {},
                            },
                            '"' => switch (@intFromEnum(key)) {
                                'j' => {
                                    const ls = grapheme.lineStart(content, cs.items[0].head);
                                    const col_px = win.preferred_col orelse platform.measureText(content[ls..cs.items[0].head], win.font_size);
                                    win.preferred_col = col_px;
                                    for (cs.items[0..cs.len]) |*c| {
                                        c.head = cursorDown(content, c.head, col_px, win.font_size);
                                    }
                                },
                                'k' => {
                                    const ls = grapheme.lineStart(content, cs.items[0].head);
                                    const col_px = win.preferred_col orelse platform.measureText(content[ls..cs.items[0].head], win.font_size);
                                    win.preferred_col = col_px;
                                    for (cs.items[0..cs.len]) |*c| {
                                        c.head = cursorUp(content, c.head, col_px, win.font_size);
                                    }
                                },
                                else => {},
                            },
                            else => {},
                            'm' => switch (@intFromEnum(key)) {
                                's' => { win.pending = .ms; },
                                'd' => { win.pending = .md; },
                                'r' => { win.pending = .mr1; },
                                else => {},
                            },
                        },
                    }
                    } else switch (@intFromEnum(key)) {
                    'H' => self.extendSelection(win, cs, .left),
                    'L' => self.extendSelection(win, cs, .right),
                    'x' => {
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        const content = buf.bytes();
                        win.preferred_col = null;
                        for (cs.items[0..cs.len]) |*c| {
                            if (grapheme.lineStart(content, c.head) == grapheme.lineStart(content, c.anchor)) {
                                c.anchor = grapheme.lineStart(content, c.head);
                            }
                            const le = grapheme.findChars(content, c.head, "\n");
                            c.head = if (le < content.len) le + 1 else content.len;
                        }
                    },
                    'X' => {
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        const content = buf.bytes();
                        win.preferred_col = null;
                        for (cs.items[0..cs.len]) |*c| {
                            if (grapheme.lineStart(content, c.head) == grapheme.lineStart(content, c.anchor)) {
                                c.anchor = grapheme.findChars(content, c.head, "\n");
                            }
                            const cur_ls = grapheme.lineStart(content, c.head);
                            c.head = if (cur_ls > 0) cur_ls - 1 else 0;
                        }
                    },
                    'h' => {
                        if (cs.hasSelection()) {
                            cs.collapseToStart();
                            win.preferred_col = null;
                        } else self.move(win, cs, .left);
                    },
                    'l' => {
                        if (cs.hasSelection()) {
                            cs.collapseToEnd();
                            win.preferred_col = null;
                        } else self.move(win, cs, .right);
                    },
                    'k' => {
                        if (mods & MOD_ALT != 0) {
                            // Move line up
                            const buf = self.getBuffer(win.buffer_id) orelse return;
                            for (cs.items[0..cs.len]) |*c| {
                                const content = buf.bytes();
                                const ls = grapheme.lineStart(content, c.head);
                                if (ls == 0) continue;
                                const prev_le = ls - 1;
                                const prev_ls = grapheme.lineStart(content, prev_le);
                                const le = grapheme.findChars(content, c.head, "\n");
                                const col_offset = c.head - ls;
                                const la_len = le - ls;
                                const lb_len = prev_le - prev_ls;
                                if (la_len > 4096 or lb_len > 4096) continue;
                                var line_a: [4096]u8 = undefined;
                                var line_b: [4096]u8 = undefined;
                                @memcpy(line_a[0..la_len], content[ls..le]);
                                @memcpy(line_b[0..lb_len], content[prev_ls..prev_le]);
                                self.bufferDelete(win.buffer_id, prev_ls, le - prev_ls);
                                self.bufferInsert(win.buffer_id, prev_ls, line_a[0..la_len]) catch {};
                                self.bufferInsert(win.buffer_id, prev_ls + la_len, "\n") catch {};
                                self.bufferInsert(win.buffer_id, prev_ls + la_len + 1, line_b[0..lb_len]) catch {};
                                c.head = prev_ls + @min(col_offset, la_len);
                                c.anchor = c.head;
                            }
                            win.preferred_col = null;
                        } else {
                            cs.clearSelections();
                            self.move(win, cs, .up);
                        }
                    },
                    'j' => {
                        if (mods & MOD_ALT != 0) {
                            // Move line down
                            const buf = self.getBuffer(win.buffer_id) orelse return;
                            var idx = cs.len;
                            while (idx > 0) {
                                idx -= 1;
                                const c = &cs.items[idx];
                                const content = buf.bytes();
                                const ls = grapheme.lineStart(content, c.head);
                                const le = grapheme.findChars(content, c.head, "\n");
                                if (le >= content.len) continue;
                                const next_ls = le + 1;
                                const next_le = grapheme.findChars(content, next_ls, "\n");
                                const col_offset = c.head - ls;
                                const la_len = le - ls;
                                const lb_len = next_le - next_ls;
                                if (la_len > 4096 or lb_len > 4096) continue;
                                var line_a: [4096]u8 = undefined;
                                var line_b: [4096]u8 = undefined;
                                @memcpy(line_a[0..la_len], content[ls..le]);
                                @memcpy(line_b[0..lb_len], content[next_ls..next_le]);
                                self.bufferDelete(win.buffer_id, ls, next_le - ls);
                                self.bufferInsert(win.buffer_id, ls, line_b[0..lb_len]) catch {};
                                self.bufferInsert(win.buffer_id, ls + lb_len, "\n") catch {};
                                self.bufferInsert(win.buffer_id, ls + lb_len + 1, line_a[0..la_len]) catch {};
                                c.head = ls + lb_len + 1 + @min(col_offset, la_len);
                                c.anchor = c.head;
                            }
                            win.preferred_col = null;
                        } else {
                            cs.clearSelections();
                            self.move(win, cs, .down);
                        }
                    },
                    'w' => {
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        const content = buf.bytes();
                        for (cs.items[0..cs.len]) |*c| {
                            c.head = wordNext(content, c.head);
                            c.anchor = c.head;
                        }
                        win.preferred_col = null;
                    },
                    'W' => {
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        const content = buf.bytes();
                        for (cs.items[0..cs.len]) |*c| {
                            c.head = wordNext(content, c.head);
                        }
                        win.preferred_col = null;
                    },
                    'b' => {
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        const content = buf.bytes();
                        for (cs.items[0..cs.len]) |*c| {
                            c.head = wordPrev(content, c.head);
                            c.anchor = c.head;
                        }
                        win.preferred_col = null;
                    },
                    'B' => {
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        const content = buf.bytes();
                        for (cs.items[0..cs.len]) |*c| {
                            c.head = wordPrev(content, c.head);
                        }
                        win.preferred_col = null;
                    },
                    'i' => {
                        if (cs.hasSelection()) self.deleteSelections(win, cs);
                        win.mode = .insert;
                    },
                    'I' => {
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        const content = buf.bytes();
                        for (cs.items[0..cs.len]) |*c| {
                            c.head = grapheme.lineStart(content, c.head);
                            c.anchor = c.head;
                        }
                        win.preferred_col = null;
                        win.mode = .insert;
                    },
                    '/' => self.openPalette(.search_forward) catch {},
                    '?' => self.openPalette(.search_backward) catch {},
                    's' => self.openPaletteForSplit(false) catch {},
                    'S' => self.openPaletteForSplit(true) catch {},
                    'v' => self.openPaletteForFilter(true) catch {},
                    'V' => self.openPaletteForFilter(false) catch {},
                    'n' => {
                        self.requireFreshMatches();
                        if (self.palette.matches.items.len == 0 or cs.len == 0) return;
                        const m = findNextMatchFrom(self.palette.matches.items, cs.items[cs.len - 1].end()) orelse return;
                        cs.clear();
                        cs.insert(.{ .head = m.end, .anchor = m.start }) catch {};
                        win.preferred_col = null;
                    },
                    'N' => {
                        self.requireFreshMatches();
                        if (self.palette.matches.items.len == 0 or cs.len == 0) return;
                        const m = findNextMatchFrom(self.palette.matches.items, cs.items[cs.len - 1].end()) orelse return;
                        cs.insert(.{ .head = m.end, .anchor = m.start }) catch {};
                        win.preferred_col = null;
                    },
                    'p' => {
                        self.requireFreshMatches();
                        if (self.palette.matches.items.len == 0 or cs.len == 0) return;
                        const m = findPrevMatchFrom(self.palette.matches.items, cs.items[0].start()) orelse return;
                        cs.clear();
                        cs.insert(.{ .head = m.end, .anchor = m.start }) catch {};
                        win.preferred_col = null;
                    },
                    'P' => {
                        self.requireFreshMatches();
                        if (self.palette.matches.items.len == 0 or cs.len == 0) return;
                        const m = findPrevMatchFrom(self.palette.matches.items, cs.items[0].start()) orelse return;
                        cs.insert(.{ .head = m.end, .anchor = m.start }) catch {};
                        win.preferred_col = null;
                    },
                    '*' => {
                        if (cs.len == 0) return;
                        self.requireFreshMatches();
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        const content = buf.bytes();
                        if (self.palette.matches.items.len == 0) {
                            const c0 = cs.items[0];
                            const term: ?[]const u8 = if (c0.isSelection())
                                content[c0.start()..c0.end()]
                            else if (wordBoundsAt(content, c0.head)) |wb|
                                content[wb.start..wb.end]
                            else
                                null;
                            if (term) |word| {
                                const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
                                if (pal_buf.len() > 0) self.bufferDelete(self.palette.buffer_id, 0, pal_buf.len());
                                self.bufferInsert(self.palette.buffer_id, 0, word) catch return;
                                const pal_cs = self.getCursorSet(self.palette.cursor_set_id) orelse return;
                                if (pal_cs.len > 0) {
                                    pal_cs.items[0].head = word.len;
                                    pal_cs.items[0].anchor = word.len;
                                }
                                self.updateMatches() catch return;
                            }
                        }
                        if (self.palette.matches.items.len > 0) {
                            cs.clear();
                            for (self.palette.matches.items) |m| {
                                cs.insert(.{ .head = m.end, .anchor = m.start }) catch break;
                            }
                        }
                        win.preferred_col = null;
                    },
                    'o' => {
                        if (cs.len == 0) return;
                        var idx = cs.len;
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        while (idx > 0) {
                            idx -= 1;
                            const c = &cs.items[idx];
                            const line_end = grapheme.findChars(buf.bytes(), c.head, "\n");
                            self.bufferInsert(win.buffer_id, line_end, "\n") catch continue;
                            c.head = line_end + 1;
                            c.anchor = c.head;
                        }
                        win.mode = .insert;
                        win.preferred_col = null;
                    },
                    'O' => {
                        if (cs.len == 0) return;
                        var idx = cs.len;
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        while (idx > 0) {
                            idx -= 1;
                            const c = &cs.items[idx];
                            const line_start = grapheme.lineStart(buf.bytes(), c.head);
                            self.bufferInsert(win.buffer_id, line_start, "\n") catch continue;
                            c.head = line_start;
                            c.anchor = c.head;
                        }
                        win.mode = .insert;
                        win.preferred_col = null;
                    },
                    'd' => self.cut(win, cs),
                    'D' => {
                        if (cs.len == 0) return;
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        // Collect line ranges from current content, then merge overlapping.
                        const content = buf.bytes();
                        const Range = struct { start: usize, end: usize };
                        var ranges: [512]Range = undefined;
                        for (cs.items[0..cs.len], 0..) |c, i| {
                            const ls = grapheme.lineStart(content, c.start());
                            const le = grapheme.findChars(content, c.end(), "\n");
                            ranges[i] = .{
                                .start = ls,
                                .end = if (le < content.len) le + 1 else content.len,
                            };
                        }
                        // Merge (cursors are sorted so ranges are in order).
                        var merged: [512]Range = undefined;
                        var n: usize = 0;
                        for (ranges[0..cs.len]) |r| {
                            if (n > 0 and r.start <= merged[n - 1].end) {
                                merged[n - 1].end = @max(merged[n - 1].end, r.end);
                            } else {
                                merged[n] = r;
                                n += 1;
                            }
                        }
                        // Delete in reverse order so positions stay valid.
                        var i = n;
                        while (i > 0) {
                            i -= 1;
                            self.bufferDelete(win.buffer_id, merged[i].start, merged[i].end - merged[i].start);
                        }
                        win.preferred_col = null;
                    },
                    'y' => self.yank(win, cs),
                    'Y' => self.paste(win, cs),
                    '\'' => {
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        const content = buf.bytes();
                        for (cs.items[0..cs.len]) |*c| {
                            c.head = grapheme.findChars(content, c.head, "\n");
                            c.anchor = c.head;
                        }
                        win.preferred_col = null;
                        win.mode = .insert;
                    },
                    'r' => { win.pending = .rl; },
                    'R' => { win.pending = .rr; },
                    'f' => { win.pending = .{ .sf1 = true }; },
                    'F' => { win.pending = .{ .sf1 = false }; },
                    ';' => self.execSneak(win, cs, win.sneak_c1, win.sneak_c2, win.sneak_forward),
                    ':' => self.execSneak(win, cs, win.sneak_c1, win.sneak_c2, !win.sneak_forward),
                    't' => {
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        const content = buf.bytes();
                        var idx = cs.len;
                        while (idx > 0) {
                            idx -= 1;
                            const c = &cs.items[idx];
                            const prev = cursorLeft(content, c.head);
                            const next = cursorRight(content, c.head);
                            if (prev < c.head and next > c.head) {
                                const left_len = c.head - prev;
                                const right_len = next - c.head;
                                var left_copy: [32]u8 = undefined;
                                var right_copy: [32]u8 = undefined;
                                @memcpy(left_copy[0..left_len], content[prev..c.head]);
                                @memcpy(right_copy[0..right_len], content[c.head..next]);
                                self.bufferDelete(win.buffer_id, prev, left_len + right_len);
                                self.bufferInsert(win.buffer_id, prev, right_copy[0..right_len]) catch {};
                                self.bufferInsert(win.buffer_id, prev + right_len, left_copy[0..left_len]) catch {};
                                c.head = cursorLeft(content, c.head);
                                c.anchor = c.head;
                            }
                        }
                        win.preferred_col = null;
                    },
                    'T' => {
                        const buf = self.getBuffer(win.buffer_id) orelse return;
                        const content = buf.bytes();
                        var idx = cs.len;
                        while (idx > 0) {
                            idx -= 1;
                            const c = &cs.items[idx];
                            // Find left word end, then start
                            if (c.head == 0 or (isWordChar(content[c.head]) and isWordChar(content[c.head-1]))) continue;
                            var lend = c.head;
                            while (lend > 0 and !isWordChar(content[lend - 1])) lend -= 1;
                            if (lend == 0) continue;
                            var lstart = lend;
                            while (lstart > 0 and isWordChar(content[lstart - 1])) lstart -= 1;
                            // Find right word start, then end
                            var rstart = c.head;
                            while (rstart < content.len and !isWordChar(content[rstart])) rstart += 1;
                            if (rstart >= content.len) continue;
                            var rend = rstart + 1;
                            while (rend < content.len and isWordChar(content[rend])) rend += 1;
                            // Words must not overlap
                            if (lend > rstart) continue;
                            const lword_len = lend - lstart;
                            const rword_len = rend - rstart;
                            const affected_len = rend - lstart;
                            if (affected_len > 256) continue;
                            var affected: [256]u8 = undefined;
                            @memcpy(affected[0..affected_len], content[lstart..rend]);
                            // Replace in reverse order to preserve offsets
                            const prev_head = c.head;
                            self.bufferDelete(win.buffer_id, lstart, affected_len);
                            self.bufferInsert(win.buffer_id, lstart, affected[0..lword_len]) catch {};
                            self.bufferInsert(win.buffer_id, lstart, affected[lend-lstart..rstart-lstart]) catch {};
                            self.bufferInsert(win.buffer_id, lstart, affected[rstart-lstart..rend-lstart]) catch {};
                            c.head = (prev_head + rword_len) - lword_len;
                            c.anchor = c.head;
                        }
                        win.preferred_col = null;
                    },
                    'g', 'c', 'a', 'A', '"' => { win.pending = .{ .prefix = @intCast(@intFromEnum(key)) }; },
                    'm' => { win.pending = .{ .prefix = 'm' }; },
                    else => {},
                    } // end single-key switch
                }, // end pending_key else / isPrintable block
            },
            .insert => switch (key) {
                .escape => win.mode = .normal,
                .arrow_left => self.move(win, cs, .left),
                .arrow_right => self.move(win, cs, .right),
                .arrow_up => self.move(win, cs, .up),
                .arrow_down => self.move(win, cs, .down),
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
                    self.insertAtCursors(win, cs, "\n");
                },
                else => if (key.isPrintable() and mods & MOD_CTRL != 0 and @intFromEnum(key) == 'w') {
                    win.preferred_col = null;
                    const buf = self.getBuffer(win.buffer_id) orelse return;
                    const content = buf.bytes();
                    var it = cs.reverseIter();
                    while (it.next()) |cursor| {
                        const prev = wordPrev(content, cursor.head);
                        if (prev < cursor.head)
                            self.bufferDelete(win.buffer_id, prev, cursor.head - prev);
                    }
                } else if (key.isPrintable()) {
                    win.preferred_col = null;
                    var encoded: [4]u8 = undefined;
                    const cp: u21 = @intCast(@intFromEnum(key));
                    const byte_len = std.unicode.utf8Encode(cp, &encoded) catch return;
                    self.insertAtCursors(win, cs, encoded[0..byte_len]);
                },
            },
            .command => {
                const pal_cs = self.getCursorSet(self.palette.cursor_set_id) orelse return;
                switch (key) {
                    .escape => self.closePalette(false),
                    .enter => self.closePalette(true),
                    .backspace => {
                        if (pal_cs.len > 0 and pal_cs.items[0].head > 0) {
                            self.bufferDelete(self.palette.buffer_id, pal_cs.items[0].head - 1, 1);
                            self.updateMatches() catch {};
                        }
                    },
                    .arrow_left => {
                        if (pal_cs.len > 0 and pal_cs.items[0].head > 0) {
                            pal_cs.items[0].head -= 1;
                            pal_cs.items[0].anchor = pal_cs.items[0].head;
                        }
                    },
                    .arrow_right => {
                        const pal_buf = self.getBuffer(self.palette.buffer_id) orelse return;
                        if (pal_cs.len > 0 and pal_cs.items[0].head < pal_buf.len()) {
                            pal_cs.items[0].head += 1;
                            pal_cs.items[0].anchor = pal_cs.items[0].head;
                        }
                    },
                    else => if (key.isPrintable()) {
                        var encoded: [4]u8 = undefined;
                        const cp: u21 = @intCast(@intFromEnum(key));
                        const byte_len = std.unicode.utf8Encode(cp, &encoded) catch return;
                        if (pal_cs.len > 0) {
                            self.bufferInsert(self.palette.buffer_id, pal_cs.items[0].head, encoded[0..byte_len]) catch return;
                            self.updateMatches() catch {};
                        }
                    },
                }
            },
        }
    }

    pub fn onKeyUp(self: *Editor, key: Key, mods: u32) void {
        _ = self;
        _ = key;
        _ = mods;
    }

    pub fn onMouse(self: *Editor, x: f32, y: f32, button: u8, kind: u8, mods: u32) void {
        const win = self.getWindow(self.focused_window) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const cs = self.getCursorSet(win.cursor_set_id) orelse return;

        switch (kind) {
            1 => { // mousedown
                if (button != 0) return;
                const pos = posFromPoint(win, buf.bytes(), x, y);
                win.preferred_col = null;
                const alt = (mods & @import("key.zig").MOD_ALT) != 0;
                if (!alt) cs.clear();
                cs.insert(Cursor.init(pos)) catch {};
                if (!alt) self.drag_anchor = pos;
            },
            0 => { // mousemove
                const anchor = self.drag_anchor orelse return;
                const pos = posFromPoint(win, buf.bytes(), x, y);
                cs.clear();
                cs.insert(.{
                    .head = pos,
                    .anchor = anchor,
                }) catch {};
            },
            2 => { // mouseup
                self.drag_anchor = null;
            },
            else => {},
        }
    }

    pub fn onScroll(self: *Editor, time_ms: f64, dx: f32, dy: f32) void {
        self.last_input_ms = time_ms;
        if (self.getWindow(self.focused_window)) |win| win.onScroll(dx, dy);
    }

    pub fn onResize(self: *Editor, width: u32, height: u32) void {
        if (self.getWindow(self.focused_window)) |win| win.onResize(width, height);
    }
};
