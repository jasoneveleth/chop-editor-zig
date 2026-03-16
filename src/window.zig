const std = @import("std");
const draw = @import("draw.zig");
const Buffer = @import("buffer.zig").Buffer;
const BufferId = @import("buffer.zig").BufferId;
const CursorSet = @import("cursor_set.zig").CursorSet;
const CursorSetId = @import("cursor_set.zig").CursorSetId;
const Match = @import("palette.zig").Match;
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

pub const PendingState = union(enum) {
    none:   void,
    prefix: u8,   // first key of a 2-key cmd (g/a/A/c/"), waiting for 2nd
    ms:     void, // 'm'+'s': waiting for surround char
    md:     void, // 'm'+'d': waiting for delete-surround char
    mr1:    void, // 'm'+'r': waiting for char1 (old delimiter)
    mr2:    u8,   // 'm'+'r'+'c1': waiting for char2 (new delimiter), stores c1
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
    preferred_col: ?f32 = null,
    pending: PendingState = .none,

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

    pub fn buildDrawList(self: *Window, dl: *draw.DrawList, buf: *const Buffer, cs: *const CursorSet, highlights: []const Match, cursor_visible: bool, dark_mode: bool) !void {
        const bg_color   = if (dark_mode) draw.Color.rgb(27, 27, 27)   else draw.Color.rgb(247, 247, 247);
        const text_color = if (dark_mode) draw.Color.rgb(204, 204, 204) else draw.Color.rgb(27, 27, 27);

        // Background
        try dl.fillRect(
            .{ .x = 0, .y = 0, .w = self.width, .h = self.height },
            bg_color,
        );

        const line_height = self.font_size * 1.4;
        const gutter_width: f32 = 8;
        const content = buf.bytes();

        // Render visible lines — highlights drawn before text so text sits on top.
        var line_y: f32 = -self.scroll_y;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i <= content.len) : (i += 1) {
            const at_end = i == content.len;
            const at_newline = !at_end and content[i] == '\n';
            if (at_newline or at_end) {
                const baseline = line_y + self.font_size;
                if (baseline >= 0 and line_y < self.height) {
                    // Draw selection highlights.
                    for (cs.iter()) |cursor| {
                        if (!cursor.isSelection()) continue;
                        const ov_s = @max(cursor.start(), line_start);
                        const ov_e = @min(cursor.end(), i);
                        if (ov_s >= ov_e) continue;
                        const hx = gutter_width + platform.measureText(content[line_start..ov_s], self.font_size);
                        const hw = platform.measureText(content[ov_s..ov_e], self.font_size);
                        try dl.fillRect(.{ .x = hx, .y = line_y, .w = hw, .h = line_height }, draw.Color.rgba(38, 120, 200, 120));
                    }

                    // Draw match highlights for this line.
                    for (highlights, 0..) |m, mi| {
                        const m_start = @max(m.start, line_start);
                        const m_end   = @min(m.end,   i);
                        if (m_start >= m_end) continue;
                        const hx = gutter_width + platform.measureText(content[line_start..m_start], self.font_size);
                        const hw = platform.measureText(content[m_start..m_end], self.font_size);
                        const color = if (mi == 0)
                            draw.Color.rgba(255, 200, 0, 180) // first match: emphasized
                        else
                            draw.Color.rgba(255, 200, 0, 60);  // rest: dim
                        try dl.fillRect(.{ .x = hx, .y = line_y, .w = hw, .h = line_height }, color);
                    }

                    try dl.drawText(
                        gutter_width, baseline,
                        content[line_start..i],
                        text_color,
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
                            if (cursor_visible) try dl.fillRect(
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

    pub fn onScroll(self: *Window, dx: f32, dy: f32) void {
        _ = dx;
        self.scroll_y = @max(0, self.scroll_y + dy);
    }

    pub fn onResize(self: *Window, width: u32, height: u32) void {
        self.width = @floatFromInt(width);
        self.height = @floatFromInt(height);
    }
};
