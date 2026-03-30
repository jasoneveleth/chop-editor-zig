const std = @import("std");
const BufferId = @import("buffer.zig").BufferId;
const CursorSetId = @import("cursor_set.zig").CursorSetId;
const CursorSet = @import("cursor_set.zig").CursorSet;
const Op = @import("op.zig").Op;

pub const Match = struct {
    start: usize,
    end: usize,
};

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
    buffer_id: BufferId,
    cursor_set_id: CursorSetId,
    /// Snapshot of focused window's cursor set, restored on Escape.
    /// start=0,len=0 until first openPalette call sets a real snapshot.
    saved_cursors: CursorSet,
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

    pub fn init(buffer_id: BufferId, cursor_set_id: CursorSetId) Palette {
        return .{
            .buffer_id = buffer_id,
            .cursor_set_id = cursor_set_id,
            // start=0 is a safe sentinel; len=0 means no cursors to restore.
            .saved_cursors = CursorSet.init(buffer_id, @enumFromInt(0)),
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
