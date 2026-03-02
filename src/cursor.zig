// A cursor is one end of a selection (the "head"), plus an anchor where
// the selection started. When anchor == head the cursor is a point with
// no selection.
pub const Cursor = struct {
    head: usize,   // byte offset, where the cursor is
    anchor: usize, // byte offset, where the selection started

    pub fn init(pos: usize) Cursor {
        return .{ .head = pos, .anchor = pos };
    }

    pub fn isSelection(self: Cursor) bool {
        return self.head != self.anchor;
    }

    pub fn selectionStart(self: Cursor) usize {
        return @min(self.head, self.anchor);
    }

    pub fn selectionEnd(self: Cursor) usize {
        return @max(self.head, self.anchor);
    }

    // Move head (and collapse anchor) to a new position.
    pub fn moveTo(self: *Cursor, pos: usize) void {
        self.head = pos;
        self.anchor = pos;
    }

    // Adjust cursor position after an insertion at `insert_pos` of `len` bytes.
    pub fn adjustForInsert(self: *Cursor, insert_pos: usize, insert_len: usize) void {
        if (self.head >= insert_pos) self.head += insert_len;
        if (self.anchor >= insert_pos) self.anchor += insert_len;
    }

    // Adjust cursor position after a deletion of `del_len` bytes starting at `del_pos`.
    pub fn adjustForDelete(self: *Cursor, del_pos: usize, del_len: usize) void {
        const del_end = del_pos + del_len;
        self.head = adjustOffset(self.head, del_pos, del_end);
        self.anchor = adjustOffset(self.anchor, del_pos, del_end);
    }
};

fn adjustOffset(offset: usize, del_start: usize, del_end: usize) usize {
    if (offset <= del_start) return offset;
    if (offset < del_end) return del_start;
    return offset - (del_end - del_start);
}
