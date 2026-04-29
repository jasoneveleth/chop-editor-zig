const std = @import("std");
const Cursor = @import("cursor.zig").Cursor;
const BufferId = @import("buffer.zig").BufferId;
const WrapRow = @import("buffer.zig").WrapRow;
const Buffer = @import("buffer.zig").Buffer;
const WindowId = @import("window.zig").WindowId;
const grapheme = @import("grapheme.zig");
const platform = @import("platform/web.zig");

pub const MAX_CURSORS = 512;

/// An offset into CursorPool.slab (distinct from BufferViewId, UndoNodeIdx, etc.)
pub const CursorPoolIdx = enum(u32) { _ };

pub const BufferViewId = packed struct(u32) {
    index: u24,
    generation: u8,
};

/// Flat slab of cursor slots.  Live buffer views have a fixed pre-allocated
/// region (MAX_CURSORS slots each).  Undo / palette snapshots are appended
/// after those regions and are never mutated after creation.
pub const CursorPool = struct {
    slab: std.ArrayList(Cursor) = .{},

    pub fn deinit(self: *CursorPool, allocator: std.mem.Allocator) void {
        self.slab.deinit(allocator);
    }

    /// Pre-allocate `count` uninitialised slots; returns start index.
    pub fn allocSlots(self: *CursorPool, allocator: std.mem.Allocator, count: u32) !CursorPoolIdx {
        const start: CursorPoolIdx = @enumFromInt(self.slab.items.len);
        try self.slab.resize(allocator, self.slab.items.len + count);
        return start;
    }

    /// Copy `src_start..src_start+len` into a *new* pool region (safe even
    /// when src lives inside this pool — copies to a temp buffer first).
    pub fn snapshotRange(self: *CursorPool, allocator: std.mem.Allocator, src_start: CursorPoolIdx, len: u32) !CursorPoolIdx {
        try self.slab.ensureUnusedCapacity(allocator, len);
        const start: CursorPoolIdx = @enumFromInt(self.slab.items.len);
        self.slab.appendSliceAssumeCapacity(self.slab.items[@intFromEnum(src_start)..][0..len]);
        return start;
    }

    pub fn slice(self: *const CursorPool, start: CursorPoolIdx, len: u32) []Cursor {
        return self.slab.items[@intFromEnum(start)..][0..len];
    }
};

pub const ReverseIter = struct {
    slice: []Cursor,
    index: usize,

    pub fn next(self: *ReverseIter) ?*Cursor {
        if (self.index == 0) return null;
        self.index -= 1;
        return &self.slice[self.index];
    }
};

/// A buffer view is a thin handle into a CursorPool: `start` is a fixed offset
/// where MAX_CURSORS slots were pre-allocated at creation time.
/// All mutations happen in-place within that region; snapshots are separate
/// pool regions written by CursorPool.snapshotRange.
pub const BufferView = struct {
    buffer_id: BufferId,
    window_id: ?WindowId = null,
    start: CursorPoolIdx,   // fixed, immutable after creation
    len: u32,
    softwrap:  bool = false,
    wrap_rows: std.ArrayListUnmanaged(WrapRow) = .{},

    pub fn init(buffer_id: BufferId, start: CursorPoolIdx) BufferView {
        return .{ .buffer_id = buffer_id, .start = start, .len = 0 };
    }

    pub fn deinit(self: *BufferView, allocator: std.mem.Allocator) void {
        self.wrap_rows.deinit(allocator);
    }

    /// Rebuild wrap_rows for this view. available_width is the renderable
    /// width in pixels (window width minus gutter).
    pub fn buildWrapRows(self: *BufferView, allocator: std.mem.Allocator, buf: *const Buffer, available_width: f32, font_size: f32) !void {
        self.wrap_rows.clearRetainingCapacity();
        const content = buf.bytes();
        const line_starts = buf.lineStarts();
        const line_count = buf.lineCount();

        for (0..line_count) |ln| {
            const line_start = line_starts[ln];
            const line_end = if (ln + 1 < line_count) line_starts[ln + 1] - 1 else content.len;

            if (!self.softwrap or line_start == line_end) {
                try self.wrap_rows.append(allocator, .{ .line = ln, .start = line_start, .end = line_end });
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
                    try self.wrap_rows.append(allocator, .{ .line = ln, .start = row_start, .end = break_at });
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
            try self.wrap_rows.append(allocator, .{ .line = ln, .start = row_start, .end = line_end });
        }
    }

    /// Insert a cursor maintaining sort order by start().
    pub fn insert(self: *BufferView, pool: *CursorPool, cursor: Cursor) !void {
        if (self.len >= MAX_CURSORS) return error.Overflow;
        // Binary search for insertion point.
        var lo: u32 = 0;
        var hi: u32 = self.len;
        const base = pool.slice(self.start, self.len);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (base[mid].start() <= cursor.start()) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // Shift elements right within the pre-allocated region.
        const all = pool.slice(self.start, self.len + 1);
        var i: u32 = self.len;
        while (i > lo) : (i -= 1) all[i] = all[i - 1];
        all[lo] = cursor;
        self.len += 1;
    }

    pub fn iter(self: *const BufferView, pool: *const CursorPool) []Cursor {
        return pool.slice(self.start, self.len);
    }

    pub fn reverseIter(self: *BufferView, pool: *CursorPool) ReverseIter {
        return .{ .slice = pool.slice(self.start, self.len), .index = self.len };
    }

    pub fn adjustForInsert(self: *BufferView, pool: *CursorPool, pos: usize, amt: usize) void {
        for (pool.slice(self.start, self.len)) |*c| c.adjustForInsert(pos, amt);
    }

    pub fn adjustForDelete(self: *BufferView, pool: *CursorPool, pos: usize, amt: usize) void {
        for (pool.slice(self.start, self.len)) |*c| c.adjustForDelete(pos, amt);
    }

    pub fn clear(self: *BufferView) void {
        self.len = 0;
    }

    pub fn hasSelection(self: *const BufferView, pool: *const CursorPool) bool {
        for (pool.slice(self.start, self.len)) |c| if (c.isSelection()) return true;
        return false;
    }

    pub fn clearSelections(self: *BufferView, pool: *CursorPool) void {
        for (pool.slice(self.start, self.len)) |*c| c.anchor = c.head;
    }

    pub fn collapseToStart(self: *BufferView, pool: *CursorPool) void {
        for (pool.slice(self.start, self.len)) |*c| {
            c.head = c.start();
            c.anchor = c.head;
        }
    }

    pub fn collapseToEnd(self: *BufferView, pool: *CursorPool) void {
        for (pool.slice(self.start, self.len)) |*c| {
            c.head = c.end();
            c.anchor = c.head;
        }
    }

    /// Overwrite this view's live region with data from a snapshot region.
    pub fn restoreFrom(self: *BufferView, pool: *CursorPool, snap_start: CursorPoolIdx, snap_len: u32) void {
        @memcpy(
            pool.slice(self.start, snap_len),
            pool.slab.items[@intFromEnum(snap_start)..][0..snap_len],
        );
        self.len = snap_len;
    }
};
