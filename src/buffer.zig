const std = @import("std");

pub const BufferId = packed struct(u32) {
    index: u24,
    generation: u8,
};

// Stub: text stored as a flat ArrayList(u8). Will become a rope.
pub const Buffer = struct {
    content:     std.ArrayList(u8),
    line_starts: std.ArrayList(usize), // line_starts[n] = byte offset of line n
    allocator:   std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Buffer {
        var self = Buffer{
            .content     = .{},
            .line_starts = .{},
            .allocator   = allocator,
        };
        try self.line_starts.append(allocator, 0);
        return self;
    }

    pub fn deinit(self: *Buffer) void {
        self.content.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
    }

    pub fn len(self: *const Buffer) usize {
        return self.content.items.len;
    }

    pub fn insert(self: *Buffer, pos: usize, text: []const u8) !void {
        try self.content.insertSlice(self.allocator, pos, text);
        try self.rebuildLineTable();
    }

    pub fn delete(self: *Buffer, pos: usize, count: usize) !void {
        const end = @min(pos + count, self.content.items.len);
        self.content.replaceRangeAssumeCapacity(pos, end - pos, &.{});
        try self.rebuildLineTable();
    }

    pub fn bytes(self: *const Buffer) []const u8 {
        return self.content.items;
    }

    pub fn slice(self: *const Buffer, start: usize, end: usize) []const u8 {
        return self.content.items[start..end];
    }

    // ── Line table ────────────────────────────────────────────────────────────

    fn rebuildLineTable(self: *Buffer) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(self.allocator, 0);
        for (self.content.items, 0..) |c, i| {
            if (c == '\n') try self.line_starts.append(self.allocator, i + 1);
        }
    }

    /// Byte offset of the first character of line n.
    pub fn lineStarts(self: *const Buffer) []const usize {
        return self.line_starts.items;
    }

    /// Number of lines (always >= 1).
    pub fn lineCount(self: *const Buffer) usize {
        return self.line_starts.items.len;
    }

    /// Binary search: byte offset → line number.
    pub fn lineAt(self: *const Buffer, byte: usize) usize {
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
