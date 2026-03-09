const std = @import("std");

pub const GraphemeIterator = struct {
    text: []const u8,
    pos: u32 = 0,

    pub fn init(text: []const u8) GraphemeIterator {
        return GraphemeIterator{
            .text = text,
            .pos = 0,
        };
    }

    pub fn next(self: *GraphemeIterator) ?[]const u8 {
        if (self.pos >= self.text.len) return null;

        const start = self.pos;

        // Get the first code point
        const len = std.unicode.utf8ByteSequenceLength(self.text[self.pos]) catch return null;
        self.pos += len;

        // Keep consuming while we should continue
        while (self.pos < self.text.len) {
            const check_pos = self.pos;
            const check_len = std.unicode.utf8ByteSequenceLength(self.text[check_pos]) catch break;
            const codepoint = std.unicode.utf8Decode(self.text[check_pos..][0..check_len]) catch break;

            // Debug output
            // std.debug.print("    Checking at pos {}: U+{X:0>4} ", .{check_pos, codepoint});

            if (codepoint == 0x200D) {
                // std.debug.print("(ZWJ) - continuing\n", .{});
                self.pos += check_len;

                // After ZWJ, consume everything until we hit another ZWJ or end
                if (self.pos < self.text.len) {
                    const next_len = std.unicode.utf8ByteSequenceLength(self.text[self.pos]) catch break;
                    // const next_cp = std.unicode.utf8Decode(self.text[self.pos..][0..next_len]) catch break;
                    // std.debug.print("    After ZWJ, found U+{X:0>4} - consuming\n", .{next_cp});
                    self.pos += next_len;

                    // Now check for combining marks on this new base
                    while (self.pos < self.text.len) {
                        const mark_len = std.unicode.utf8ByteSequenceLength(self.text[self.pos]) catch break;
                        const mark_cp = std.unicode.utf8Decode(self.text[self.pos..][0..mark_len]) catch break;

                        if (self.isCombiningMark(mark_cp) or self.isVariationSelector(mark_cp)) {
                            // std.debug.print("    Found combining/VS U+{X:0>4} - consuming\n", .{mark_cp});
                            self.pos += mark_len;
                        } else if (mark_cp == 0x200D) {
                            // Another ZWJ! Keep going
                            // std.debug.print("    Found another ZWJ - looping\n", .{});
                            break; // Break inner loop to continue outer loop
                        } else {
                            // std.debug.print("    Found U+{X:0>4} - not continuing\n", .{mark_cp});
                            return self.text[start..self.pos];
                        }
                    }
                }
            } else if (self.isCombiningMark(codepoint)) {
                // std.debug.print("(combining) - continuing\n", .{});
                self.pos += check_len;
            } else if (self.isVariationSelector(codepoint)) {
                // std.debug.print("(VS) - continuing\n", .{});
                self.pos += check_len;
            } else {
                // std.debug.print("(other) - stopping\n", .{});
                break;
            }
        }

        return self.text[start..self.pos];
    }

    fn isCombiningMark(_: *GraphemeIterator, cp: u21) bool {
        return (cp >= 0x0300 and cp <= 0x036F)   // Combining Diacritical Marks
            or (cp >= 0x1DC0 and cp <= 0x1DFF)   // Combining Diacritical Marks Supplement
            or (cp >= 0x20D0 and cp <= 0x20FF)   // Combining Diacritical Marks for Symbols
            or (cp >= 0xFE20 and cp <= 0xFE2F);  // Combining Half Marks
    }

    fn isVariationSelector(_: *GraphemeIterator, cp: u21) bool {
        return (cp >= 0xFE00 and cp <= 0xFE0F)     // Variation Selectors
            or (cp >= 0xE0100 and cp <= 0xE01EF);  // Variation Selectors Supplement
    }
};

// ── File-scope utilities ───────────────────────────────────────────────────

/// Advance one grapheme from pos.
pub fn nextGrapheme(text: []const u8, pos: usize) usize {
    var it = GraphemeIterator{ .text = text, .pos = @intCast(pos) };
    _ = it.next();
    return @as(usize, it.pos);
}

/// Step back one grapheme from pos (skips UTF-8 continuation bytes).
pub fn prevGrapheme(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and (text[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// Scan forward from pos; return start of first grapheme whose first byte is in chars, or text.len.
pub fn findChars(text: []const u8, pos: usize, chars: []const u8) usize {
    var it = GraphemeIterator{ .text = text, .pos = @intCast(pos) };
    while (true) {
        const gpos: usize = it.pos;
        const g = it.next() orelse break;
        for (chars) |c| if (g[0] == c) return gpos;
    }
    return text.len;
}

/// Scan forward from pos; return start of first grapheme whose first byte is NOT in chars, or text.len.
pub fn findNonChars(text: []const u8, pos: usize, chars: []const u8) usize {
    var it = GraphemeIterator{ .text = text, .pos = @intCast(pos) };
    while (true) {
        const gpos: usize = it.pos;
        const g = it.next() orelse break;
        var found = false;
        for (chars) |c| if (g[0] == c) { found = true; break; };
        if (!found) return gpos;
    }
    return text.len;
}

/// Backward scan from pos (exclusive); return position of the last byte in chars found, or null.
pub fn findCharsBack(text: []const u8, pos: usize, chars: []const u8) ?usize {
    var i = pos;
    while (i > 0) {
        i -= 1;
        for (chars) |c| if (text[i] == c) return i;
    }
    return null;
}

/// Count graphemes in text[from..to].
pub fn graphemeCount(text: []const u8, from: usize, to: usize) usize {
    var it = GraphemeIterator{ .text = text[0..to], .pos = @intCast(from) };
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    return count;
}

/// Advance n graphemes from start, stopping at end. Returns resulting position.
pub fn advanceGraphemes(text: []const u8, start: usize, end: usize, n: usize) usize {
    var it = GraphemeIterator{ .text = text[0..end], .pos = @intCast(start) };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (it.next() == null) break;
    }
    return @as(usize, it.pos);
}

pub fn lineStart(content: []const u8, head: usize) usize {
    return if (findCharsBack(content, head, "\n")) |nl| nl + 1 else 0;
}