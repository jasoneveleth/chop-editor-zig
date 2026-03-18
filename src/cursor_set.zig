const std = @import("std");
const Cursor = @import("cursor.zig").Cursor;
const BufferId = @import("buffer.zig").BufferId;

pub const MAX_CURSORS = 512;

pub const CursorSetId = packed struct(u32) {
    index: u24,
    generation: u8,
};

/// Flat slab of cursor slots.  Live cursor sets have a fixed pre-allocated
/// region (MAX_CURSORS slots each).  Undo / palette snapshots are appended
/// after those regions and are never mutated after creation.
pub const CursorPool = struct {
    slab: std.ArrayList(Cursor) = .{},

    pub fn deinit(self: *CursorPool, allocator: std.mem.Allocator) void {
        self.slab.deinit(allocator);
    }

    /// Pre-allocate `count` uninitialised slots; returns start index.
    pub fn allocSlots(self: *CursorPool, allocator: std.mem.Allocator, count: u32) !u32 {
        const start: u32 = @intCast(self.slab.items.len);
        try self.slab.resize(allocator, self.slab.items.len + count);
        return start;
    }

    /// Copy `src_start..src_start+len` into a *new* pool region (safe even
    /// when src lives inside this pool — copies to a temp buffer first).
    pub fn snapshotRange(self: *CursorPool, allocator: std.mem.Allocator, src_start: u32, len: u32) !u32 {
        var tmp: [MAX_CURSORS]Cursor = undefined;
        @memcpy(tmp[0..len], self.slab.items[src_start..][0..len]);
        const start: u32 = @intCast(self.slab.items.len);
        try self.slab.appendSlice(allocator, tmp[0..len]);
        return start;
    }

    pub fn slice(self: *const CursorPool, start: u32, len: u32) []Cursor {
        return self.slab.items[start..][0..len];
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

/// A cursor set is now a thin handle: `start` is a fixed offset into a
/// CursorPool where MAX_CURSORS slots were pre-allocated at creation time.
/// All mutations happen in-place within that region; snapshots are separate
/// pool regions written by CursorPool.snapshotRange.
pub const CursorSet = struct {
    buffer_id: BufferId,
    start: u32,   // fixed, immutable after creation
    len: u32,

    pub fn init(buffer_id: BufferId, start: u32) CursorSet {
        return .{ .buffer_id = buffer_id, .start = start, .len = 0 };
    }

    /// Insert a cursor maintaining sort order by start().
    pub fn insert(self: *CursorSet, pool: *CursorPool, cursor: Cursor) !void {
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

    pub fn iter(self: *const CursorSet, pool: *const CursorPool) []Cursor {
        return pool.slice(self.start, self.len);
    }

    pub fn reverseIter(self: *CursorSet, pool: *CursorPool) ReverseIter {
        return .{ .slice = pool.slice(self.start, self.len), .index = self.len };
    }

    pub fn adjustForInsert(self: *CursorSet, pool: *CursorPool, pos: usize, len: usize) void {
        for (pool.slice(self.start, self.len)) |*c| c.adjustForInsert(pos, len);
    }

    pub fn adjustForDelete(self: *CursorSet, pool: *CursorPool, pos: usize, len: usize) void {
        for (pool.slice(self.start, self.len)) |*c| c.adjustForDelete(pos, len);
    }

    pub fn clear(self: *CursorSet) void {
        self.len = 0;
    }

    pub fn hasSelection(self: *const CursorSet, pool: *const CursorPool) bool {
        for (pool.slice(self.start, self.len)) |c| if (c.isSelection()) return true;
        return false;
    }

    pub fn clearSelections(self: *CursorSet, pool: *CursorPool) void {
        for (pool.slice(self.start, self.len)) |*c| c.anchor = c.head;
    }

    pub fn collapseToStart(self: *CursorSet, pool: *CursorPool) void {
        for (pool.slice(self.start, self.len)) |*c| {
            c.head = c.start();
            c.anchor = c.head;
        }
    }

    pub fn collapseToEnd(self: *CursorSet, pool: *CursorPool) void {
        for (pool.slice(self.start, self.len)) |*c| {
            c.head = c.end();
            c.anchor = c.head;
        }
    }

    /// Overwrite this set's live region with data from a snapshot region.
    pub fn restoreFrom(self: *CursorSet, pool: *CursorPool, snap_start: u32, snap_len: u32) void {
        @memcpy(
            pool.slice(self.start, snap_len),
            pool.slab.items[snap_start..][0..snap_len],
        );
        self.len = snap_len;
    }
};
