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
};