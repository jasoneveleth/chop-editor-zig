const std = @import("std");
const BufferId = @import("buffer.zig").BufferId;
const CursorSetId = @import("cursor_set.zig").CursorSetId;
const CursorSet = @import("cursor_set.zig").CursorSet;

pub const Match = struct {
    start: usize,
    end: usize,
};

pub const Direction = enum { forward, backward };

pub const Palette = struct {
    buffer_id: BufferId,
    cursor_set_id: CursorSetId,
    /// Snapshot of focused window's cursor set, restored on Escape.
    saved_cursors: CursorSet,
    /// All match positions in the focused buffer, recomputed on each keystroke.
    matches: std.ArrayList(Match),
    matches_stale: bool = false,
    direction: Direction = .forward,

    pub fn init(buffer_id: BufferId, cursor_set_id: CursorSetId) Palette {
        return .{
            .buffer_id = buffer_id,
            .cursor_set_id = cursor_set_id,
            .saved_cursors = CursorSet.init(buffer_id),
            .matches = .{},
        };
    }

    pub fn deinit(self: *Palette, allocator: std.mem.Allocator) void {
        self.matches.deinit(allocator);
    }
};
