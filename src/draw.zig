const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    // Packs to 0xRRGGBBAA for passing to JS as a single u32.
    pub fn toU32(self: Color) u32 {
        return (@as(u32, self.r) << 24) |
            (@as(u32, self.g) << 16) |
            (@as(u32, self.b) << 8) |
            @as(u32, self.a);
    }
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Cmd = union(enum) {
    fill_rect: struct { rect: Rect, color: Color },
    // text slice is valid for the duration of the render() call that built this list.
    draw_text: struct { x: f32, y: f32, text: []const u8, color: Color, size: f32 },
    clip_rect: Rect,
    clear_clip,
};

pub const DrawList = struct {
    cmds: std.ArrayList(Cmd),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DrawList {
        return .{ .cmds = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *DrawList) void {
        self.cmds.deinit(self.allocator);
    }

    pub fn clear(self: *DrawList) void {
        self.cmds.clearRetainingCapacity();
    }

    pub fn fillRect(self: *DrawList, rect: Rect, color: Color) !void {
        try self.cmds.append(self.allocator, .{ .fill_rect = .{ .rect = rect, .color = color } });
    }

    pub fn drawText(self: *DrawList, x: f32, y: f32, text: []const u8, color: Color, size: f32) !void {
        if (text.len == 0) {
            return;
        }
        try self.cmds.append(self.allocator, .{ .draw_text = .{ .x = x, .y = y, .text = text, .color = color, .size = size } });
    }

    pub fn clipRect(self: *DrawList, rect: Rect) !void {
        try self.cmds.append(self.allocator, .{ .clip_rect = rect });
    }

    pub fn clearClip(self: *DrawList) !void {
        try self.cmds.append(self.allocator, .clear_clip);
    }
};
