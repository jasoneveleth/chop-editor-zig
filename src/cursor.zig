const std = @import("std");
const grapheme = @import("grapheme.zig");
const platform = @import("platform/web.zig");

pub const Cursor = struct {
    /// The active (moving) end of the selection.
    head: usize,
    /// The fixed end of the selection. Equal to head when there is no selection.
    anchor: usize,

    pub fn init(pos: usize) Cursor {
        return .{ .head = pos, .anchor = pos };
    }

    pub fn start(self: Cursor) usize {
        return @min(self.head, self.anchor);
    }

    pub fn end(self: Cursor) usize {
        return @max(self.head, self.anchor);
    }

    pub fn isSelection(self: Cursor) bool {
        return self.head != self.anchor;
    }

    pub fn adjustForInsert(self: *Cursor, pos: usize, len: usize) void {
        if (self.head >= pos) self.head += len;
        if (self.anchor >= pos) self.anchor += len;
    }

    pub fn adjustForDelete(self: *Cursor, pos: usize, len: usize) void {
        self.head = clampDelete(self.head, pos, len);
        self.anchor = clampDelete(self.anchor, pos, len);
    }
};

fn clampDelete(v: usize, pos: usize, len: usize) usize {
    if (v <= pos) return v;
    if (v < pos + len) return pos;
    return v - len;
}

pub const Bounds = struct { start: usize, end: usize };

pub fn cursorLeft(content: []const u8, head: usize) usize {
    return grapheme.prevGrapheme(content, head);
}

pub fn cursorRight(content: []const u8, head: usize) usize {
    return grapheme.nextGrapheme(content, head);
}

pub fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isSTNL(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

pub fn wordNext(content: []const u8, pos: usize) usize {
    var i = pos;
    if (i >= content.len) return content.len;
    if (isWordChar(content[i])) {
        while (i < content.len and isWordChar(content[i])) i += 1;
    } else if (!isSTNL(content[i])) {
        while (i < content.len and !isWordChar(content[i]) and !isSTNL(content[i])) i += 1;
    }
    while (i < content.len and isSTNL(content[i])) i += 1;
    return i;
}

pub fn wordPrev(content: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and isSTNL(content[i - 1])) i -= 1;
    if (i == 0) return 0;
    if (isWordChar(content[i - 1])) {
        while (i > 0 and isWordChar(content[i - 1])) i -= 1;
    } else {
        while (i > 0 and !isWordChar(content[i - 1]) and !isSTNL(content[i - 1])) i -= 1;
    }
    return i;
}

/// Walk graphemes on [line_start, line_end), return the byte offset whose
/// measured x-position is closest to target_x.
pub fn closestPosToX(content: []const u8, line_start: usize, line_end: usize, target_x: f32, font_size: f32) usize {
    var it = grapheme.GraphemeIterator{ .text = content[0..line_end], .pos = @intCast(line_start) };
    var prev_pos: usize = line_start;
    var prev_x: f32 = 0;
    while (it.next()) |_| {
        const cur_pos: usize = @as(usize, it.pos);
        const cur_x = platform.measureText(content[line_start..cur_pos], font_size);
        if (cur_x >= target_x) {
            return if (target_x - prev_x <= cur_x - target_x) prev_pos else cur_pos;
        }
        prev_pos = cur_pos;
        prev_x = cur_x;
    }
    return prev_pos;
}

pub fn cursorUp(content: []const u8, head: usize, col_px: f32, font_size: f32) usize {
    const ls = grapheme.lineStart(content, head);
    if (ls == 0) return head;
    const prev_le = ls - 1;
    const prev_ls = grapheme.lineStart(content, prev_le);
    return closestPosToX(content, prev_ls, prev_le, col_px, font_size);
}

pub fn cursorDown(content: []const u8, head: usize, col_px: f32, font_size: f32) usize {
    const le = grapheme.findChars(content, head, "\n");
    if (le >= content.len) return head;
    const next_ls = le + 1;
    const next_le = grapheme.findChars(content, next_ls, "\n");
    return closestPosToX(content, next_ls, next_le, col_px, font_size);
}

pub fn sneakForward(content: []const u8, from: usize, c1: u8, c2: u8) ?usize {
    var i = from + 1;
    while (i + 1 < content.len) : (i += 1) {
        if (content[i] == c1 and content[i + 1] == c2) return i;
    }
    return null;
}

pub fn sneakBackward(content: []const u8, from: usize, c1: u8, c2: u8) ?usize {
    var i = from;
    while (i > 0) {
        i -= 1;
        if (i + 1 < content.len and content[i] == c1 and content[i + 1] == c2) return i;
    }
    return null;
}

pub fn quoteBounds(content: []const u8, pos: usize, quote: u8) ?Bounds {
    // search backward for opening quote
    var s = pos;
    while (true) {
        if (s == 0) return null;
        s -= 1;
        if (content[s] == quote) break;
    }
    // search forward for closing quote
    var e = pos;
    while (e < content.len and content[e] != quote) e += 1;
    if (e >= content.len) return null;
    return .{ .start = s, .end = e };
}

pub fn parenBounds(content: []const u8, pos: usize, open: u8, close: u8) ?Bounds {
    // search backward for opening paren (tracking nesting)
    var depth: usize = 0;
    var s = pos;
    while (true) {
        if (s == 0) return null;
        s -= 1;
        if (content[s] == close) depth += 1
        else if (content[s] == open) {
            if (depth == 0) break;
            depth -= 1;
        }
    }
    // search forward for matching closing paren
    depth = 0;
    var e = pos;
    while (e < content.len) : (e += 1) {
        if (content[e] == open) depth += 1
        else if (content[e] == close) {
            if (depth == 0) break;
            depth -= 1;
        }
    }
    if (e >= content.len) return null;
    return .{ .start = s, .end = e };
}

pub fn wordBoundsAt(content: []const u8, pos: usize) ?Bounds {
    if (pos >= content.len or !isWordChar(content[pos])) return null;
    var s = pos;
    while (s > 0 and isWordChar(content[s - 1])) s -= 1;
    var e = pos + 1;
    while (e < content.len and isWordChar(content[e])) e += 1;
    return .{ .start = s, .end = e };
}

pub fn surroundPair(ch: u8) struct { open: u8, close: u8 } {
    return switch (ch) {
        '(', ')' => .{ .open = '(', .close = ')' },
        '[', ']' => .{ .open = '[', .close = ']' },
        '{', '}' => .{ .open = '{', .close = '}' },
        '<', '>' => .{ .open = '<', .close = '>' },
        else     => .{ .open = ch,  .close = ch  },
    };
}

pub fn surroundBounds(content: []const u8, pos: usize, ch: u8) ?Bounds {
    return switch (ch) {
        '(', ')' => parenBounds(content, pos, '(', ')'),
        '[', ']' => parenBounds(content, pos, '[', ']'),
        '{', '}' => parenBounds(content, pos, '{', '}'),
        '<', '>' => parenBounds(content, pos, '<', '>'),
        else     => quoteBounds(content, pos, ch),
    };
}
