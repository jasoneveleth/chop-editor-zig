// Minimal libc stubs for wasm32-freestanding.
// Tree-sitter's C code calls malloc/free/realloc/calloc — we satisfy those
// symbols here using Zig's GPA so we get proper sub-page allocations.
//
// Included by main.zig via a comptime block when targeting freestanding WASM.

const std = @import("std");

var gpa: std.heap.GeneralPurposeAllocator(.{ .safety = false }) = .{};

// Each allocation is prefixed with an 8-byte header storing the payload size,
// so that free() can recover the slice length without a separate bookkeeping map.
const HEADER: usize = 8;

export fn malloc(size: usize) ?*anyopaque {
    if (size == 0) return null;
    const buf = gpa.allocator().alloc(u8, size + HEADER) catch return null;
    std.mem.writeInt(u64, buf[0..8], @intCast(size), .little);
    return buf.ptr + HEADER;
}

export fn free(ptr: ?*anyopaque) void {
    const p: [*]u8 = @ptrCast(ptr orelse return);
    const base = p - HEADER;
    const size: usize = @intCast(std.mem.readInt(u64, base[0..8], .little));
    gpa.allocator().free(base[0 .. size + HEADER]);
}

export fn realloc(ptr: ?*anyopaque, new_size: usize) ?*anyopaque {
    if (ptr == null) return malloc(new_size);
    if (new_size == 0) { free(ptr); return null; }
    const p: [*]u8 = @ptrCast(ptr.?);
    const base = p - HEADER;
    const old_size: usize = @intCast(std.mem.readInt(u64, base[0..8], .little));
    const new_buf = gpa.allocator().realloc(base[0 .. old_size + HEADER], new_size + HEADER) catch return null;
    std.mem.writeInt(u64, new_buf[0..8], @intCast(new_size), .little);
    return new_buf.ptr + HEADER;
}

export fn calloc(n: usize, size: usize) ?*anyopaque {
    const total = n *| size;
    const p = malloc(total) orelse return null;
    @memset(@as([*]u8, @ptrCast(p))[0..total], 0);
    return p;
}

export fn strlen(s: [*:0]const u8) usize {
    return std.mem.len(s);
}

export fn abort() noreturn {
    @panic("libc abort()");
}
