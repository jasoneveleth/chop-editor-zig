const std = @import("std");

pub const BufferId = packed struct(u32) {
    index: u24,
    generation: u8,
};

// Stub: text stored as a flat ArrayList(u8). Will become a rope.
pub const Buffer = struct {
    content: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Buffer {
        return .{ .content = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        self.content.deinit(self.allocator);
    }

    pub fn len(self: *const Buffer) usize {
        return self.content.items.len;
    }

    pub fn insert(self: *Buffer, pos: usize, text: []const u8) !void {
        try self.content.insertSlice(self.allocator, pos, text);
    }

    pub fn delete(self: *Buffer, pos: usize, count: usize) void {
        const end = @min(pos + count, self.content.items.len);
        self.content.replaceRangeAssumeCapacity(pos, end - pos, &.{});
    }

    pub fn bytes(self: *const Buffer) []const u8 {
        return self.content.items;
    }

    pub fn slice(self: *const Buffer, start: usize, end: usize) []const u8 {
        return self.content.items[start..end];
    }
};
