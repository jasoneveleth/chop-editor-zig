const std = @import("std");
const draw = @import("draw.zig");
const Buffer = @import("buffer.zig").Buffer;
const BufferId = @import("buffer.zig").BufferId;
const CursorSet = @import("cursor_set.zig").CursorSet;
const CursorSetId = @import("cursor_set.zig").CursorSetId;
const CursorPool = @import("cursor_set.zig").CursorPool;
const Match = @import("palette.zig").Match;
const highlight = @import("highlight.zig");
const Colorscheme = @import("op.zig").Colorscheme;
// Hardcoded to web for now — measureText is needed during layout.
const platform = @import("platform/web.zig");

const TagStyle = struct {
    fg: draw.Color,
    bg: ?draw.Color = null,
};

fn tagStyle(tag: highlight.Tag, scheme: Colorscheme) TagStyle {
    return switch (scheme) {
        .onedark => switch (tag) {
            .default      => .{ .fg = draw.Color.rgb(204, 204, 204) },
            .keyword      => .{ .fg = draw.Color.rgb(198, 120, 221) },
            .string       => .{ .fg = draw.Color.rgb(152, 195, 121) },
            .comment      => .{ .fg = draw.Color.rgb( 92, 100, 114) },
            .number       => .{ .fg = draw.Color.rgb(209, 154,  99) },
            .builtin      => .{ .fg = draw.Color.rgb( 86, 182, 194) },
            .punctuation  => .{ .fg = draw.Color.rgb(150, 150, 150) },
            .identifier   => .{ .fg = draw.Color.rgb(224, 108, 117) },
            .identifier_decl => .{ .fg = draw.Color.rgb(224, 108, 117) },
            .type_primitive  => .{ .fg = draw.Color.rgb(215, 186, 127) },
            .fn_name         => .{ .fg = draw.Color.rgb( 97, 175, 239) },
        },
        .alabaster => switch (tag) {
            .default      => .{ .fg = draw.Color.rgb( 27,  27,  27) },
            .keyword      => .{ .fg = draw.Color.rgb( 27,  27,  27) },
            .string       => .{ .fg = draw.Color.rgb( 16,  96,  16), .bg = draw.Color.rgb(224, 244, 224) },
            .comment      => .{ .fg = draw.Color.rgb(128,  20,  20), .bg = draw.Color.rgb(248, 228, 228) },
            .number       => .{ .fg = draw.Color.rgb( 16,  96,  16), .bg = draw.Color.rgb(224, 244, 224) },
            .builtin      => .{ .fg = draw.Color.rgb( 27,  27,  27) },
            .punctuation  => .{ .fg = draw.Color.rgb( 79,  79,  79) },
            .identifier   => .{ .fg = draw.Color.rgb( 27,  27,  27) },
            .identifier_decl => .{ .fg = draw.Color.rgb( 78,  18, 130), .bg = draw.Color.rgb(236, 224, 248) },
            .type_primitive  => .{ .fg = draw.Color.rgb( 27,  27,  27) },
            .fn_name         => .{ .fg = draw.Color.rgb( 27,  27,  27) },
        },
    };
}

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
    rl:     void, // 'r': waiting for replacement char (replaces char to left)
    rr:     void, // 'R': waiting for replacement char (replaces char to right)
    sf1:    bool, // 'f'/'F': waiting for first sneak char; true=forward
    sf2:    struct { forward: bool, c1: u8 }, // 'f'/'F'+c1: waiting for second sneak char
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
    sneak_c1: u8 = 0,
    sneak_c2: u8 = 0,
    sneak_forward: bool = true,
    last_cmd: u8 = 0,

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

    pub fn buildDrawList(self: *Window, dl: *draw.DrawList, buf: *const Buffer, cs: *const CursorSet, pool: *const CursorPool, highlights: []const Match, spans: []const highlight.Span, cursor_visible: bool, scheme: Colorscheme) !void {
        const bg_color   = switch (scheme) { .onedark => draw.Color.rgb(41, 44, 51),   .alabaster => draw.Color.rgb(247, 247, 247) };
        const text_color = switch (scheme) { .onedark => draw.Color.rgb(204, 204, 204), .alabaster => draw.Color.rgb(27,  27,  27)  };

        // Background
        try dl.fillRect(
            .{ .x = 0, .y = 0, .w = self.width, .h = self.height },
            bg_color,
        );

        const line_height = self.font_size * 1.4;
        const gutter_width: f32 = 8;
        const content = buf.bytes();

        const line_starts = buf.lineStarts();
        const line_count  = buf.lineCount();

        // First visible line (floor of scroll_y / line_height, clamped).
        const first_line: usize = @min(
            @as(usize, @intFromFloat(self.scroll_y / line_height)),
            line_count - 1,
        );

        // Seed span_idx at the first span not fully before the first visible line.
        var span_idx: usize = blk: {
            const first_byte = line_starts[first_line];
            var lo: usize = 0;
            var hi: usize = spans.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (spans[mid].end <= first_byte) lo = mid + 1 else hi = mid;
            }
            break :blk lo;
        };

        // Render visible lines — highlights drawn before text so text sits on top.
        for (first_line..line_count) |ln| {
            const line_start = line_starts[ln];
            const line_end   = if (ln + 1 < line_count) line_starts[ln + 1] - 1 else content.len;
            const line_y     = -self.scroll_y + @as(f32, @floatFromInt(ln)) * line_height;
            const baseline   = line_y + self.font_size;

            if (line_y >= self.height) break;

            // Advance span_idx past spans that ended before this line.
            while (span_idx < spans.len and spans[span_idx].end <= line_start) span_idx += 1;

            // Draw selection highlights.
            for (cs.iter(pool)) |cursor| {
                if (!cursor.isSelection()) continue;
                const ov_s = @max(cursor.start(), line_start);
                const ov_e = @min(cursor.end(), line_end);
                if (ov_s >= ov_e) continue;
                const hx = gutter_width + platform.measureText(content[line_start..ov_s], self.font_size);
                const hw = platform.measureText(content[ov_s..ov_e], self.font_size);
                const sel_color = switch (scheme) {
                    .onedark  => draw.Color.rgba( 38, 120, 200, 120),
                    .alabaster => draw.Color.rgb(204, 236, 249),
                };
                try dl.fillRect(.{ .x = hx, .y = line_y, .w = hw, .h = line_height }, sel_color);
            }

            // Draw match highlights for this line.
            for (highlights, 0..) |m, mi| {
                const m_start = @max(m.start, line_start);
                const m_end   = @min(m.end,   line_end);
                if (m_start >= m_end) continue;
                const hx = gutter_width + platform.measureText(content[line_start..m_start], self.font_size);
                const hw = platform.measureText(content[m_start..m_end], self.font_size);
                const color = if (mi == 0)
                    draw.Color.rgba(255, 200, 0, 180) // first match: emphasized
                else
                    draw.Color.rgba(255, 200, 0, 60);  // rest: dim
                try dl.fillRect(.{ .x = hx, .y = line_y, .w = hw, .h = line_height }, color);
            }

            // Draw line text in colored segments.
            var pos: usize = line_start;
            var x: f32 = gutter_width;
            var si: usize = span_idx;
            while (pos < line_end) {
                if (si < spans.len and spans[si].start < line_end) {
                    const span = spans[si];
                    const seg_s = @max(span.start, pos);
                    const seg_e = @min(span.end, line_end);
                    // Default-colored text before this span.
                    if (seg_s > pos) {
                        const pre = content[pos..seg_s];
                        try dl.drawText(x, baseline, pre, text_color, self.font_size);
                        x += platform.measureText(pre, self.font_size);
                        pos = seg_s;
                    }
                    // Colored span text.
                    if (seg_e > pos) {
                        const seg = content[pos..seg_e];
                        const style = tagStyle(span.tag, scheme);
                        const seg_w = platform.measureText(seg, self.font_size);
                        if (style.bg) |bg| if (span.start >= line_start) try dl.fillRect(.{ .x = x, .y = line_y, .w = seg_w, .h = line_height }, bg);
                        try dl.drawText(x, baseline, seg, style.fg, self.font_size);
                        x += seg_w;
                        pos = seg_e;
                    }
                    if (span.end <= line_end) si += 1 else break;
                } else {
                    try dl.drawText(x, baseline, content[pos..line_end], text_color, self.font_size);
                    break;
                }
            }
        }

        // Draw each cursor at its accurate screen position.
        const normal_color = draw.Color.rgb(0, 196, 255);   // #00C4FF
        const insert_color = draw.Color.rgb(255, 116, 108); // #FFA66C
        const cursor_color = if (self.mode == .insert) insert_color else normal_color;

        for (cs.iter(pool)) |cursor| {
            const ln      = buf.lineAt(cursor.head);
            const cl_start = line_starts[ln];
            const cl_y    = -self.scroll_y + @as(f32, @floatFromInt(ln)) * line_height;
            if (cl_y + line_height >= 0 and cl_y < self.height) {
                const cx = gutter_width + platform.measureText(content[cl_start..cursor.head], self.font_size);
                if (cursor_visible) try dl.fillRect(
                    .{ .x = cx - 1, .y = cl_y, .w = 2, .h = line_height },
                    cursor_color,
                );
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
