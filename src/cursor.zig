pub const Cursor = struct {
    /// The active (moving) end of the selection. Valid byte offset into the buffer.
    head: usize,
    /// anchor = head + offset.
    /// 0   = point cursor (no selection).
    /// < 0 = anchor is before head (selected rightward, e.g. head=20 offset=-10 → anchor=10).
    /// > 0 = anchor is after head (selected leftward).
    offset: i64,

    pub fn init(pos: usize) Cursor {
        return .{ .head = pos, .offset = 0 };
    }

    pub fn anchor(self: Cursor) usize {
        const a = @as(i64, @intCast(self.head)) + self.offset;
        return @intCast(@max(0, a));
    }

    pub fn start(self: Cursor) usize {
        return @min(self.head, self.anchor());
    }

    pub fn end(self: Cursor) usize {
        return @max(self.head, self.anchor());
    }

    pub fn isSelection(self: Cursor) bool {
        return self.offset != 0;
    }

    pub fn adjustForInsert(self: *Cursor, pos: usize, len: usize) void {
        const anch: i64 = @intCast(self.anchor());
        const pos_i: i64 = @intCast(pos);
        const len_i: i64 = @intCast(len);
        const new_head: usize = if (self.head >= pos) self.head + len else self.head;
        const new_anchor: i64 = if (anch >= pos_i) anch + len_i else anch;
        self.head = new_head;
        self.offset = new_anchor - @as(i64, @intCast(new_head));
    }

    pub fn adjustForDelete(self: *Cursor, pos: usize, len: usize) void {
        const del_end = pos + len;
        const anch = self.anchor();
        const new_head = clampDelete(self.head, pos, len, del_end);
        const new_anchor = clampDelete(anch, pos, len, del_end);
        self.head = new_head;
        self.offset = @as(i64, @intCast(new_anchor)) - @as(i64, @intCast(new_head));
    }
};

fn clampDelete(v: usize, pos: usize, len: usize, del_end: usize) usize {
    if (v <= pos) return v;
    if (v < del_end) return pos;
    return v - len;
}
