const std = @import("std");
const Op = @import("op.zig").Op;

pub const OpQueue = struct {
    items: std.ArrayList(Op) = .{},

    pub fn deinit(self: *OpQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn push(self: *OpQueue, allocator: std.mem.Allocator, op: Op) void {
        self.items.append(allocator, op) catch {};
    }

    pub fn pop(self: *OpQueue) ?Op {
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    pub fn clear(self: *OpQueue) void {
        self.items.clearRetainingCapacity();
    }
};
