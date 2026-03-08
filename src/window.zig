const std = @import("std");
const draw = @import("draw.zig");
const Buffer = @import("buffer.zig").Buffer;
const BufferId = @import("buffer.zig").BufferId;
const Cursor = @import("cursor.zig").Cursor;

pub const WindowId = packed struct(u32) {
    index: u24,
    generation: u8,
};

pub const Mode = enum {
    normal,
    insert,
    command,
};

pub const Window = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    buffer_id: BufferId,
    cursors: std.ArrayList(Cursor),
    scroll_x: f32,
    scroll_y: f32,
    width: f32,
    height: f32,
    font_size: f32,

    pub fn init(allocator: std.mem.Allocator, buffer_id: BufferId, width: u32, height: u32) !Window {
        var win = Window{
            .allocator = allocator,
            .mode = .normal,
            .buffer_id = buffer_id,
            .cursors = .{},
            .scroll_x = 0,
            .scroll_y = 0,
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
            .font_size = 14,
        };
        // Start with one cursor at the beginning of the buffer.
        try win.cursors.append(allocator, Cursor.init(0));
        return win;
    }

    pub fn deinit(self: *Window) void {
        self.cursors.deinit(self.allocator);
    }

    pub fn buildDrawList(self: *Window, dl: *draw.DrawList, buf: *const Buffer) !void {
        // Background
        try dl.fillRect(
            .{ .x = 0, .y = 0, .w = self.width, .h = self.height },
            draw.Color.rgb(30, 30, 30),
        );

        const line_height = self.font_size * 1.4;
        const gutter_width: f32 = 8; // left margin

        // Render visible lines by splitting on newlines.
        var line_y: f32 = -self.scroll_y;
        var line_start: usize = 0;
        const content = buf.bytes();

        var i: usize = 0;
        while (i <= content.len) : (i += 1) {
            const at_end = i == content.len;
            const at_newline = !at_end and content[i] == '\n';

            if (at_newline or at_end) {
                const baseline = line_y + self.font_size;
                if (baseline >= 0 and line_y < self.height) {
                    const line = content[line_start..i];
                    try dl.drawText(
                        gutter_width,
                        baseline,
                        line,
                        draw.Color.rgb(204, 204, 204),
                        self.font_size,
                    );
                }
                line_start = i + 1;
                line_y += line_height;
                if (line_y > self.height) break;
            }
        }

        // Cursors: stub — draw a fixed cursor rect until we have pixel-accurate
        // layout from measureText.
        const normal_color = draw.Color.rgb(0, 196, 255); // iA Writer blue #00C4FF
        const insert_color = draw.Color.rgb(223, 41, 53); // #df2935
        if (self.mode == .insert) {
            try dl.drawCursor(
                .{ .x = gutter_width, .y = -self.scroll_y, .w = 2, .h = line_height },
                insert_color,
            );
        } else {
            try dl.drawCursor(
                .{ .x = gutter_width, .y = -self.scroll_y, .w = 2, .h = line_height },
                normal_color,
            );
        }
    }

    pub fn onKey(self: *Window, keycode: u32, mods: u32) void {
        _ = keycode;
        _ = mods;
        _ = self;
        // TODO: dispatch to commands based on mode
    }

    pub fn onChar(self: *Window, codepoint: u32, buf: *Buffer) void {
        if (self.mode != .insert) return;
        var encoded: [4]u8 = undefined;
        const byte_len = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch return;
        for (self.cursors.items) |*cursor| {
            buf.insert(cursor.head, encoded[0..byte_len]) catch return;
            // Adjust all other cursors for this insertion.
            for (self.cursors.items) |*other| {
                if (other != cursor) {
                    other.adjustForInsert(cursor.head, byte_len);
                }
            }
            cursor.head += byte_len;
            cursor.anchor = cursor.head;
        }
    }

    pub fn onScroll(self: *Window, dx: f32, dy: f32) void {
        _ = dx;
        self.scroll_y = @max(0, self.scroll_y + dy);
    }

    pub fn onResize(self: *Window, width: u32, height: u32) void {
        self.width = @floatFromInt(width);
        self.height = @floatFromInt(height);
    }
};
