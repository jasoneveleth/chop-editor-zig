const std = @import("std");
const BufferId = @import("buffer.zig").BufferId;
const Op = @import("op.zig").Op;
const Colorscheme = @import("op.zig").Colorscheme;
const BufferView = @import("buffer_view.zig").BufferView;

pub const InputField = struct {
    buf: [256]u8 = undefined,
    len: u16 = 0,
    cursor: u16 = 0,

    pub fn bytes(self: *const InputField) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn textLen(self: *const InputField) usize {
        return self.len;
    }

    pub fn clear(self: *InputField) void {
        self.len = 0;
        self.cursor = 0;
    }

    pub fn insertSlice(self: *InputField, text: []const u8) void {
        const avail = @as(u16, @intCast(self.buf.len)) - self.len;
        const n: u16 = @intCast(@min(text.len, avail));
        if (n == 0) return;
        // Shift existing text right to make room.
        std.mem.copyBackwards(u8, self.buf[self.cursor + n .. self.len + n], self.buf[self.cursor..self.len]);
        @memcpy(self.buf[self.cursor .. self.cursor + n], text[0..n]);
        self.len += n;
        self.cursor += n;
    }

    pub fn deleteBack(self: *InputField) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        std.mem.copyForwards(u8, self.buf[self.cursor .. self.len - 1], self.buf[self.cursor + 1 .. self.len]);
        self.len -= 1;
    }

    pub fn moveLeft(self: *InputField) void {
        if (self.cursor > 0) self.cursor -= 1;
    }

    pub fn moveRight(self: *InputField) void {
        if (self.cursor < self.len) self.cursor += 1;
    }

    pub fn setText(self: *InputField, text: []const u8) void {
        const n: u16 = @intCast(@min(text.len, self.buf.len));
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
        self.cursor = n;
    }
};

pub const Match = struct {
    start: usize,
    end: usize,
};

pub const MatchScore = struct {
    /// 0 = empty pattern (preserve order), 1–5 = ranked tiers, 255 = no match.
    tier: u8,
    /// Position of first matched char; lower = better within same tier.
    pos: usize,
    /// For fuzzy tier only: total gap chars between matched chars.
    gaps: usize,

    pub const NO_MATCH = MatchScore{ .tier = 255, .pos = 0, .gaps = 0 };

    pub fn lessThan(self: MatchScore, other: MatchScore) bool {
        if (self.tier != other.tier) return self.tier < other.tier;
        if (self.pos  != other.pos)  return self.pos  < other.pos;
        return self.gaps < other.gaps;
    }
};

/// Score how well `pattern` matches `label` for picker ranking.
/// Returns NO_MATCH if no match is possible.
pub fn scoreMatch(pattern: []const u8, label: []const u8) MatchScore {
    if (pattern.len == 0) return .{ .tier = 0, .pos = 0, .gaps = 0 };

    // Word boundary: position 0 or immediately after a space.
    // Tier 1: case-sensitive match at a word boundary.
    {
        var pos: usize = 0;
        while (pos + pattern.len <= label.len) : (pos += 1) {
            if ((pos == 0 or label[pos - 1] == ' ') and
                std.mem.eql(u8, label[pos .. pos + pattern.len], pattern))
                return .{ .tier = 1, .pos = pos, .gaps = 0 };
        }
    }
    // Tier 2: case-insensitive match at a word boundary.
    {
        var pos: usize = 0;
        while (pos + pattern.len <= label.len) : (pos += 1) {
            if ((pos == 0 or label[pos - 1] == ' ') and
                std.ascii.eqlIgnoreCase(label[pos .. pos + pattern.len], pattern))
                return .{ .tier = 2, .pos = pos, .gaps = 0 };
        }
    }
    // Tier 3: case-sensitive substring anywhere.
    if (std.mem.indexOf(u8, label, pattern)) |p|
        return .{ .tier = 3, .pos = p, .gaps = 0 };
    // Tier 4: case-insensitive substring anywhere.
    if (indexOfIgnoreCase(label, pattern)) |p|
        return .{ .tier = 4, .pos = p, .gaps = 0 };
    // Tier 5: fuzzy — all pattern chars found in order.
    return fuzzyScore(pattern, label);
}

fn indexOfIgnoreCase(label: []const u8, pattern: []const u8) ?usize {
    if (pattern.len > label.len) return null;
    var i: usize = 0;
    while (i + pattern.len <= label.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(label[i .. i + pattern.len], pattern)) return i;
    }
    return null;
}

fn fuzzyScore(pattern: []const u8, label: []const u8) MatchScore {
    var li: usize = 0;
    var pi: usize = 0;
    var first_pos: usize = 0;
    var gaps: usize = 0;
    var prev: usize = 0;
    while (li < label.len and pi < pattern.len) : (li += 1) {
        if (std.ascii.toLower(label[li]) == std.ascii.toLower(pattern[pi])) {
            if (pi == 0) first_pos = li;
            if (pi > 0) gaps += li - prev - 1;
            prev = li;
            pi += 1;
        }
    }
    if (pi == pattern.len) return .{ .tier = 5, .pos = first_pos, .gaps = gaps };
    return MatchScore.NO_MATCH;
}

/// In-place quicksort of parallel `indices`/`scores` arrays by score (ascending).
/// Uses Lomuto partition with last-element pivot.
pub fn sortResults(indices: []usize, scores: []MatchScore) void {
    if (indices.len <= 1) return;
    // Partition: pivot = last element.
    const pivot = scores[indices.len - 1];
    var i: usize = 0;
    for (0..indices.len - 1) |j| {
        if (scores[j].lessThan(pivot)) {
            std.mem.swap(usize,       &indices[i], &indices[j]);
            std.mem.swap(MatchScore,  &scores[i],  &scores[j]);
            i += 1;
        }
    }
    std.mem.swap(usize,      &indices[i], &indices[indices.len - 1]);
    std.mem.swap(MatchScore, &scores[i],  &scores[indices.len - 1]);
    sortResults(indices[0..i],      scores[0..i]);
    sortResults(indices[i + 1..],   scores[i + 1..]);
}

pub const PreviewKind = enum {
    search_highlights,
    none,
};

pub const PickerItem = struct {
    label: []const u8,
    op_on_confirm: Op,
};

pub const PaletteConfig = struct {
    prompt_symbol: []const u8,
    op_kind: Op.PaletteOpKind,
    require_selection: bool = false,
    prepopulate_selection: bool = true,
    preview: PreviewKind = .none,
    picker_items: []const PickerItem = &.{},
};

pub const Palette = struct {
    input: InputField = .{},
    /// Snapshot of focused window's cursor set, restored on Escape.
    /// start=0,len=0 until first openPalette call sets a real snapshot.
    saved_cursors: BufferView,
    /// All match positions in the focused buffer, recomputed on each keystroke.
    matches: std.ArrayList(Match),
    matches_stale: bool = false,
    /// Non-null when the palette is open. Stores config for the current prompt session.
    active: ?PaletteConfig = null,
    /// Scratch buffer for the match-count string passed to the DrawList.
    /// Must not be stack-allocated — DrawList stores raw slices that are
    /// rendered after the drawPalette stack frame is gone.
    count_buf: [32]u8 = undefined,
    /// Picker items and selected index within the filtered list.
    picker_items: []const PickerItem = &.{},
    picker_selected: usize = 0,

    pub fn init() Palette {
        return .{
            // start=0 is a safe sentinel; len=0 means no cursors to restore.
            .saved_cursors = BufferView.init(.{ .index = 0, .generation = 0 }, @enumFromInt(0)),
            .matches = .{},
        };
    }

    pub fn isOpen(self: *const Palette) bool {
        return self.active != null;
    }

    pub fn promptSymbol(self: *const Palette) []const u8 {
        return if (self.active) |cfg| cfg.prompt_symbol else "/";
    }

    pub fn deinit(self: *Palette, allocator: std.mem.Allocator) void {
        self.matches.deinit(allocator);
    }
};

// ── Match helpers ──────────────────────────────────────────────────────────

/// First match with start >= from; wraps to first if none found.
pub fn findNextMatchFrom(matches: []const Match, from: usize) ?Match {
    for (matches) |m| if (m.start >= from) return m;
    if (matches.len > 0) return matches[0];
    return null;
}

/// Last match with end <= from; wraps to last if none found.
pub fn findPrevMatchFrom(matches: []const Match, from: usize) ?Match {
    var i = matches.len;
    while (i > 0) {
        i -= 1;
        if (matches[i].end <= from) return matches[i];
    }
    if (matches.len > 0) return matches[matches.len - 1];
    return null;
}

// ── Settings palette items ─────────────────────────────────────────────────

pub const SETTINGS_ITEMS = [_]PickerItem{
    .{ .label = "Tab Width", .op_on_confirm = .tab_width_palette },
    .{ .label = "Language",  .op_on_confirm = .language_palette },
    .{ .label = "Theme",     .op_on_confirm = .colorscheme_palette },
    .{ .label = "Soft Wrap", .op_on_confirm = .toggle_softwrap },
};

pub const TAB_WIDTH_ITEMS = [_]PickerItem{
    .{ .label = "2", .op_on_confirm = .{ .set_tab_width = 2 } },
    .{ .label = "4", .op_on_confirm = .{ .set_tab_width = 4 } },
    .{ .label = "8", .op_on_confirm = .{ .set_tab_width = 8 } },
};

pub const LANGUAGE_ITEMS = [_]PickerItem{
    .{ .label = "Zig",  .op_on_confirm = .{ .set_language = .zig } },
    .{ .label = "None", .op_on_confirm = .{ .set_language = .none } },
};

pub const COLORSCHEME_ITEMS = [_]PickerItem{
    .{ .label = "OneDark",   .op_on_confirm = .{ .set_colorscheme = .onedark } },
    .{ .label = "Alabaster", .op_on_confirm = .{ .set_colorscheme = .alabaster } },
};
