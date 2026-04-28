const std = @import("std");
const platform = @import("platform/web.zig");
const grapheme = @import("grapheme.zig");
const undo_mod = @import("undo.zig");
const BufferView = @import("buffer_view.zig").BufferView;
const CursorPool = @import("buffer_view.zig").CursorPool;

pub const BufferId = packed struct(u32) {
    index: u24,
    generation: u8,
};

// ── Text ──────────────────────────────────────────────────────────────────────
// Raw content + line table. No undo, no stored allocator.

pub const Text = struct {
    content:     std.ArrayListUnmanaged(u8)    = .{},
    line_starts: std.ArrayListUnmanaged(usize) = .{},

    pub fn init(allocator: std.mem.Allocator) !Text {
        var self = Text{};
        try self.line_starts.append(allocator, 0);
        return self;
    }

    pub fn deinit(self: *Text, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
        self.line_starts.deinit(allocator);
    }

    pub fn len(self: *const Text) usize {
        return self.content.items.len;
    }

    pub fn insert(self: *Text, allocator: std.mem.Allocator, pos: usize, text: []const u8) !void {
        try self.content.insertSlice(allocator, pos, text);
        try self.rebuildLineTable(allocator);
    }

    pub fn delete(self: *Text, allocator: std.mem.Allocator, pos: usize, count: usize) !void {
        const end = @min(pos + count, self.content.items.len);
        self.content.replaceRangeAssumeCapacity(pos, end - pos, &.{});
        try self.rebuildLineTable(allocator);
    }

    pub fn bytes(self: *const Text) []const u8 {
        return self.content.items;
    }

    pub fn slice(self: *const Text, start: usize, end: usize) []const u8 {
        return self.content.items[start..end];
    }

    fn rebuildLineTable(self: *Text, allocator: std.mem.Allocator) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(allocator, 0);
        for (self.content.items, 0..) |c, i| {
            if (c == '\n') try self.line_starts.append(allocator, i + 1);
        }
    }

    pub fn lineStarts(self: *const Text) []const usize {
        return self.line_starts.items;
    }

    pub fn lineCount(self: *const Text) usize {
        return self.line_starts.items.len;
    }

    /// Binary search: byte offset → line number.
    pub fn lineAt(self: *const Text, byte: usize) usize {
        const ls = self.line_starts.items;
        var lo: usize = 0;
        var hi: usize = ls.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (ls[mid] <= byte) lo = mid else hi = mid;
        }
        return lo;
    }
};

// UndoHistory and related types are in undo.zig

// ── Softwrap ───────────────────────────────────────────────────────────────────

pub const WrapRow = struct {
    line:  usize, // logical line index
    start: usize, // buffer byte offset of row start
    end:   usize, // buffer byte offset of row end (exclusive, before \n)
};

// ── Buffer ────────────────────────────────────────────────────────────────────
// Text + its own undo history.

pub const Buffer = struct {
    text:      Text,
    history:   undo_mod.UndoHistory = .{},
    allocator: std.mem.Allocator,
    softwrap:  bool = false,
    wrap_rows: std.ArrayListUnmanaged(WrapRow) = .{},

    pub fn init(allocator: std.mem.Allocator) !Buffer {
        return .{
            .text      = try Text.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.text.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.wrap_rows.deinit(self.allocator);
    }

    // ── Mutations ─────────────────────────────────────────────────────────

    pub fn insert(self: *Buffer, pos: usize, new_text: []const u8) !void {
        try self.text.insert(self.allocator, pos, new_text);
        self.history.recordInsert(self.allocator, pos, new_text);
    }

    pub fn delete(self: *Buffer, pos: usize, count: usize) !void {
        const end = @min(pos + count, self.text.len());
        self.history.recordDelete(self.allocator, pos, self.text.slice(pos, end));
        try self.text.delete(self.allocator, pos, count);
    }

    // ── Undo / redo wrappers ───────────────────────────────────────────────

    pub fn undo(self: *Buffer, cs: *BufferView, pool: *CursorPool) void {
        self.history.undo(&self.text, self.allocator, cs, pool);
    }

    pub fn redo(self: *Buffer, cs: *BufferView, pool: *CursorPool) void {
        self.history.redo(&self.text, self.allocator, cs, pool);
    }

    pub fn undoOlder(self: *Buffer, cs: *BufferView, pool: *CursorPool) void {
        self.history.undoOlder(&self.text, self.allocator, cs, pool);
    }

    pub fn undoNewer(self: *Buffer, cs: *BufferView, pool: *CursorPool) void {
        self.history.undoNewer(&self.text, self.allocator, cs, pool);
    }

    // ── Read-only delegates ────────────────────────────────────────────────

    pub fn len(self: *const Buffer) usize {
        return self.text.len();
    }

    pub fn bytes(self: *const Buffer) []const u8 {
        return self.text.bytes();
    }

    pub fn slice(self: *const Buffer, start: usize, end: usize) []const u8 {
        return self.text.slice(start, end);
    }

    pub fn lineStarts(self: *const Buffer) []const usize {
        return self.text.lineStarts();
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.text.lineCount();
    }

    pub fn lineAt(self: *const Buffer, byte: usize) usize {
        return self.text.lineAt(byte);
    }

    /// Rebuild wrap_rows based on softwrap setting and current content.
    /// available_width is the renderable width in pixels (window width minus gutter).
    pub fn buildWrapRows(self: *Buffer, available_width: f32, font_size: f32) !void {
        self.wrap_rows.clearRetainingCapacity();
        const content = self.bytes();
        const line_starts = self.lineStarts();
        const line_count = self.lineCount();

        for (0..line_count) |ln| {
            const line_start = line_starts[ln];
            const line_end = if (ln + 1 < line_count) line_starts[ln + 1] - 1 else content.len;

            if (!self.softwrap or line_start == line_end) {
                try self.wrap_rows.append(self.allocator, .{ .line = ln, .start = line_start, .end = line_end });
                continue;
            }

            var row_start = line_start;
            var x_acc: f32 = 0;
            var last_break: usize = line_start;
            var it = grapheme.GraphemeIterator{ .text = content[0..line_end], .pos = @intCast(line_start) };
            var g_start: usize = line_start;
            while (it.next()) |g| {
                const g_end: usize = @intCast(it.pos);
                const gw = platform.measureTextWithPrefix(content[row_start..g_start], g, font_size);
                if (x_acc + gw > available_width and g_start > row_start) {
                    const break_at = if (last_break > row_start) last_break else g_start;
                    try self.wrap_rows.append(self.allocator, .{ .line = ln, .start = row_start, .end = break_at });
                    row_start = break_at;
                    last_break = row_start;
                    x_acc = platform.measureText(content[row_start..g_start], font_size);
                    const new_gw = platform.measureTextWithPrefix(content[row_start..g_start], g, font_size);
                    x_acc += new_gw;
                } else {
                    x_acc += gw;
                }
                if (g[0] == ' ' or g[0] == '\t') last_break = g_end;
                g_start = g_end;
            }
            try self.wrap_rows.append(self.allocator, .{ .line = ln, .start = row_start, .end = line_end });
        }
    }
};
