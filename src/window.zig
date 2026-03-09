const std = @import("std");
const draw = @import("draw.zig");
const Buffer = @import("buffer.zig").Buffer;
const BufferId = @import("buffer.zig").BufferId;
const CursorSet = @import("cursor_set.zig").CursorSet;
const CursorSetId = @import("cursor_set.zig").CursorSetId;
// Hardcoded to web for now — measureText is needed during layout.
const platform = @import("platform/web.zig");

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
    mode: Mode,
    buffer_id: BufferId,
    cursor_set_id: CursorSetId,
    scroll_x: f32,
    scroll_y: f32,
    width: f32,
    height: f32,
    font_size: f32,

    pub fn init(buffer_id: BufferId, cursor_set_id: CursorSetId, width: u32, height: u32) Window {
        return .{
            .mode = .normal,
            .buffer_id = buffer_id,
            .cursor_set_id = cursor_set_id,
            .scroll_x = 0,
            .scroll_y = 0,
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
            .font_size = 14,
        };
    }

    // No deinit — Window owns no heap memory.

    pub fn buildDrawList(self: *Window, dl: *draw.DrawList, buf: *const Buffer, cs: *const CursorSet) !void {
        // Background
        try dl.fillRect(
            .{ .x = 0, .y = 0, .w = self.width, .h = self.height },
            draw.Color.rgb(30, 30, 30),
        );

        const line_height = self.font_size * 1.4;
        const gutter_width: f32 = 8;
        const content = buf.bytes();

        // Render visible lines.
        var line_y: f32 = -self.scroll_y;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i <= content.len) : (i += 1) {
            const at_end = i == content.len;
            const at_newline = !at_end and content[i] == '\n';
            if (at_newline or at_end) {
                const baseline = line_y + self.font_size;
                if (baseline >= 0 and line_y < self.height) {
                    try dl.drawText(
                        gutter_width, baseline,
                        content[line_start..i],
                        draw.Color.rgb(204, 204, 204),
                        self.font_size,
                    );
                }
                line_start = i + 1;
                line_y += line_height;
                if (line_y > self.height) break;
            }
        }

        // Draw each cursor at its accurate screen position.
        const normal_color = draw.Color.rgb(0, 196, 255); // #00C4FF
        const insert_color = draw.Color.rgb(223, 41, 53);  // #df2935
        const cursor_color = if (self.mode == .insert) insert_color else normal_color;

        for (cs.iter()) |cursor| {
            var cl_start: usize = 0;
            var cl_y: f32 = -self.scroll_y;
            var j: usize = 0;
            while (j <= content.len) : (j += 1) {
                const at_end_j = j == content.len;
                const at_nl_j = !at_end_j and content[j] == '\n';
                if (at_nl_j or at_end_j) {
                    if (cursor.head >= cl_start and cursor.head <= j) {
                        if (cl_y + line_height >= 0 and cl_y < self.height) {
                            const cx = gutter_width + platform.measureText(
                                content[cl_start..cursor.head],
                                self.font_size,
                            );
                            try dl.drawCursor(
                                .{ .x = cx - 1, .y = cl_y, .w = 2, .h = line_height },
                                cursor_color,
                            );
                        }
                        break;
                    }
                    cl_start = j + 1;
                    cl_y += line_height;
                }
            }
        }
    }

    pub fn onKey(self: *Window, keycode: u32, mods: u32) void {
        _ = mods;
        switch (self.mode) {
            .normal => switch (keycode) {
                73 => self.mode = .insert, // i
                else => {},
            },
            .insert => switch (keycode) {
                27 => self.mode = .normal, // Escape
                else => {},
            },
            .command => switch (keycode) {
                27 => self.mode = .normal, // Escape
                else => {},
            },
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
