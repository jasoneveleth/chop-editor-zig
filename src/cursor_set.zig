const Cursor = @import("cursor.zig").Cursor;
const BufferId = @import("buffer.zig").BufferId;

pub const MAX_CURSORS = 512;

pub const CursorSetId = packed struct(u32) {
    index: u24,
    generation: u8,
};

pub const ReverseIter = struct {
    slice: []const Cursor,
    index: usize,

    pub fn next(self: *ReverseIter) ?Cursor {
        if (self.index == 0) return null;
        self.index -= 1;
        return self.slice[self.index];
    }
};

pub const CursorSet = struct {
    buffer_id: BufferId,
    buf: [MAX_CURSORS]Cursor,
    len: usize,

    pub fn init(buffer_id: BufferId) CursorSet {
        return .{ .buffer_id = buffer_id, .buf = undefined, .len = 0 };
    }

    /// Insert a cursor maintaining sort order by start(). Returns error if at capacity.
    pub fn insert(self: *CursorSet, cursor: Cursor) !void {
        if (self.len >= MAX_CURSORS) return error.Overflow;
        // Binary search for insertion point.
        var lo: usize = 0;
        var hi: usize = self.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.buf[mid].start() <= cursor.start()) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // Shift elements right to make room.
        var i: usize = self.len;
        while (i > lo) : (i -= 1) self.buf[i] = self.buf[i - 1];
        self.buf[lo] = cursor;
        self.len += 1;
    }

    pub fn iter(self: *const CursorSet) []const Cursor {
        return self.buf[0..self.len];
    }

    pub fn reverseIter(self: *const CursorSet) ReverseIter {
        return .{ .slice = self.buf[0..self.len], .index = self.len };
    }

    pub fn adjustForInsert(self: *CursorSet, pos: usize, len: usize) void {
        for (self.buf[0..self.len]) |*cursor| cursor.adjustForInsert(pos, len);
    }

    pub fn adjustForDelete(self: *CursorSet, pos: usize, len: usize) void {
        for (self.buf[0..self.len]) |*cursor| cursor.adjustForDelete(pos, len);
    }

    pub fn clear(self: *CursorSet) void {
        self.len = 0;
    }

    pub fn hasSelection(self: *const CursorSet) bool {
        for (self.buf[0..self.len]) |c| if (c.isSelection()) return true;
        return false;
    }

    pub fn clearSelections(self: *CursorSet) void {
        for (self.buf[0..self.len]) |*c| c.offset = 0;
    }

    pub fn collapseToStart(self: *CursorSet) void {
        for (self.buf[0..self.len]) |*c| { c.head = c.start(); c.offset = 0; }
    }

    pub fn collapseToEnd(self: *CursorSet) void {
        for (self.buf[0..self.len]) |*c| { c.head = c.end(); c.offset = 0; }
    }
};
