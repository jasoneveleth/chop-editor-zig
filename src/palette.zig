const std = @import("std");
const BufferId = @import("buffer.zig").BufferId;
const CursorSetId = @import("cursor_set.zig").CursorSetId;
const CursorSet = @import("cursor_set.zig").CursorSet;

pub const Match = struct {
    start: usize,
    end: usize,
};

pub const PaletteIntent = enum { search_forward, search_backward, split, split_complement, filter_keep, filter_drop };

pub const Palette = struct {
    buffer_id: BufferId,
    cursor_set_id: CursorSetId,
    /// Snapshot of focused window's cursor set, restored on Escape.
    /// start=0,len=0 until first openPalette call sets a real snapshot.
    saved_cursors: CursorSet,
    /// All match positions in the focused buffer, recomputed on each keystroke.
    matches: std.ArrayList(Match),
    matches_stale: bool = false,
    intent: PaletteIntent = .search_forward,

    pub fn init(buffer_id: BufferId, cursor_set_id: CursorSetId) Palette {
        return .{
            .buffer_id = buffer_id,
            .cursor_set_id = cursor_set_id,
            // start=0 is a safe sentinel; len=0 means no cursors to restore.
            .saved_cursors = CursorSet.init(buffer_id, @enumFromInt(0)),
            .matches = .{},
        };
    }

    pub fn deinit(self: *Palette, allocator: std.mem.Allocator) void {
        self.matches.deinit(allocator);
    }
};
