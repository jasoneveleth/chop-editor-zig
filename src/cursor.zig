pub const Cursor = struct {
    /// The active (moving) end of the selection.
    head: usize,
    /// The fixed end of the selection. Equal to head when there is no selection.
    anchor: usize,

    pub fn init(pos: usize) Cursor {
        return .{ .head = pos, .anchor = pos };
    }

    pub fn start(self: Cursor) usize {
        return @min(self.head, self.anchor);
    }

    pub fn end(self: Cursor) usize {
        return @max(self.head, self.anchor);
    }

    pub fn isSelection(self: Cursor) bool {
        return self.head != self.anchor;
    }

    pub fn adjustForInsert(self: *Cursor, pos: usize, len: usize) void {
        if (self.head >= pos) self.head += len;
        if (self.anchor >= pos) self.anchor += len;
    }

    pub fn adjustForDelete(self: *Cursor, pos: usize, len: usize) void {
        self.head = clampDelete(self.head, pos, len);
        self.anchor = clampDelete(self.anchor, pos, len);
    }
};

fn clampDelete(v: usize, pos: usize, len: usize) usize {
    if (v <= pos) return v;
    if (v < pos + len) return pos;
    return v - len;
}
