const std = @import("std");
const draw = @import("draw.zig");
const keys = @import("keys.zig");
const editor = @import("editor.zig");
const buffer = @import("buffer.zig");
const bview = @import("buffer_view.zig");
const palette = @import("palette.zig");
const highlighter = @import("highlighter.zig");
const platform = @import("platform/web.zig");
const crsr = @import("cursor.zig");

const Key = keys.Key;
const KeyChord = keys.KeyChord;
const Editor = editor.Editor;
const Buffer = buffer.Buffer;
const WrapRow = buffer.WrapRow;
const BufferId = buffer.BufferId;
const BufferView = bview.BufferView;
const BufferViewId = bview.BufferViewId;
const CursorPool = bview.CursorPool;
const Match = palette.Match;
const Colorscheme = palette.Colorscheme;

const TagStyle = struct {
    fg: draw.Color,
    bg: ?draw.Color = null,
};

fn tagStyle(tag: highlighter.Tag, scheme: Colorscheme) TagStyle {
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
            .punctuation  => .{ .fg = draw.Color.rgb(160, 160, 160) },
            .identifier   => .{ .fg = draw.Color.rgb( 27,  27,  27) },
            .identifier_decl => .{ .fg = draw.Color.rgb( 78,  18, 130), .bg = draw.Color.rgb(236, 224, 248) },
            .type_primitive  => .{ .fg = draw.Color.rgb( 27,  27,  27) },
            .fn_name         => .{ .fg = draw.Color.rgb( 27,  27,  27) },
        },
    };
}

pub fn findRowForPos(rows: []const WrapRow, pos: usize) usize {
    var best: usize = 0;
    for (rows, 0..) |row, i| {
        if (pos >= row.start) best = i else break;
    }
    return best;
}

pub fn cursorUpWrapped(content: []const u8, head: usize, col_px: f32, font_size: f32, rows: []const WrapRow) usize {
    const ri = findRowForPos(rows, head);
    if (ri == 0) return head;
    const prev = rows[ri - 1];
    return crsr.closestPosToX(content, prev.start, prev.end, col_px, font_size);
}

pub fn cursorDownWrapped(content: []const u8, head: usize, col_px: f32, font_size: f32, rows: []const WrapRow) usize {
    const ri = findRowForPos(rows, head);
    if (ri + 1 >= rows.len) return head;
    const next = rows[ri + 1];
    return crsr.closestPosToX(content, next.start, next.end, col_px, font_size);
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

pub const Window = struct {
    mode: Mode,
    buffer_id: BufferId,
    buffer_view_id: BufferViewId,
    scroll_x: f32,
    scroll_y: f32,
    width: f32,
    height: f32,
    font_size: f32,
    preferred_col: ?f32 = null,
    /// Set by multi-key commands; called on next key press before normal dispatch.
    /// Cleared to null after the handler returns.
    pending_key_handler: ?*const fn (ed: *Editor, chord: KeyChord) void = null,
    /// Scratch byte for multi-key sequences that need to pass a char between handlers.
    pending_char: u8 = 0,
    sneak_c1: u8 = 0,
    sneak_c2: u8 = 0,
    sneak_forward: bool = true,
    last_cmd: u8 = 0,

    pub fn init(buffer_id: BufferId, buffer_view_id: BufferViewId, width: u32, height: u32) Window {
        return .{
            .mode = .normal,
            .buffer_id = buffer_id,
            .buffer_view_id = buffer_view_id,
            .scroll_x = 0,
            .scroll_y = 0,
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
            .font_size = 14,
        };
    }

    // No deinit — Window owns no heap memory.

    pub fn buildDrawList(self: *Window, dl: *draw.DrawList, buf: *const Buffer, cs: *const BufferView, pool: *const CursorPool, highlights: []const Match, spans: []const highlighter.Span, cursor_visible: bool, scheme: Colorscheme) !void {
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

        const rows = cs.wrap_rows.items;
        if (rows.len == 0) return;

        // First visible row (floor of scroll_y / line_height, clamped).
        const first_row: usize = @min(
            @as(usize, @intFromFloat(self.scroll_y / line_height)),
            rows.len - 1,
        );

        // Seed span_idx at the first span not fully before the first visible row.
        var span_idx: usize = blk: {
            const first_byte = rows[first_row].start;
            var lo: usize = 0;
            var hi: usize = spans.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (spans[mid].end <= first_byte) lo = mid + 1 else hi = mid;
            }
            break :blk lo;
        };

        // Render visible rows — highlights drawn before text so text sits on top.
        for (first_row..rows.len) |ri| {
            const row      = rows[ri];
            const line_start = row.start;
            const line_end   = row.end;
            const line_y     = -self.scroll_y + @as(f32, @floatFromInt(ri)) * line_height;
            const baseline   = line_y + self.font_size;

            if (line_y >= self.height) break;

            // Advance span_idx past spans that ended before this line.
            while (span_idx < spans.len and spans[span_idx].end <= line_start) span_idx += 1;

            // Draw syntax highlight backgrounds first (so selections paint over them).
            {
                var si2: usize = span_idx;
                while (si2 < spans.len and spans[si2].start < line_end) : (si2 += 1) {
                    const span = spans[si2];
                    const style = tagStyle(span.tag, scheme);
                    if (style.bg == null) continue;
                    const bg = style.bg.?;
                    const seg_s = @max(span.start, line_start);
                    const seg_e = @min(span.end, line_end);
                    if (seg_s >= seg_e) continue;
                    var bg_x = gutter_width + platform.measureText(content[line_start..seg_s], self.font_size);
                    var bg_w = platform.measureText(content[seg_s..seg_e], self.font_size);
                    if (span.start < line_start) {
                        // Trim leading whitespace from bg on soft-wrap continuation rows.
                        var ws = seg_s;
                        while (ws < seg_e and (content[ws] == ' ' or content[ws] == '\t')) ws += 1;
                        if (ws > seg_s) {
                            const ws_w = platform.measureText(content[seg_s..ws], self.font_size);
                            bg_x += ws_w;
                            bg_w -= ws_w;
                        }
                    }
                    if (bg_w > 0) try dl.fillRect(.{ .x = bg_x, .y = line_y, .w = bg_w, .h = line_height }, bg);
                }
            }

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
            const ri  = findRowForPos(rows, cursor.head);
            const row = rows[ri];
            const cl_y = -self.scroll_y + @as(f32, @floatFromInt(ri)) * line_height;
            if (cl_y + line_height >= 0 and cl_y < self.height) {
                const cx = gutter_width + platform.measureText(content[row.start..cursor.head], self.font_size);
                if (cursor_visible) try dl.fillRect(
                    .{ .x = cx - 1, .y = cl_y, .w = 2, .h = line_height },
                    cursor_color,
                );
            }
        }
    }

    pub fn ensureCursorVisible(self: *Window, cs: *const BufferView, pool: *const CursorPool) void {
        if (cs.len == 0 or cs.wrap_rows.items.len == 0) return;
        const line_height = self.font_size * 1.4;
        const items = cs.iter(pool);

        // Scroll up if top cursor is above viewport.
        const top_ri = findRowForPos(cs.wrap_rows.items, items[0].head);
        const top_y = @as(f32, @floatFromInt(top_ri)) * line_height;
        if (top_y < self.scroll_y) {
            self.scroll_y = top_y;
        }

        // Scroll down if bottom cursor is below viewport.
        const bot_ri = findRowForPos(cs.wrap_rows.items, items[cs.len - 1].head);
        const bot_y = @as(f32, @floatFromInt(bot_ri)) * line_height;
        if (bot_y + line_height > self.scroll_y + self.height) {
            self.scroll_y = bot_y + line_height - self.height;
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
