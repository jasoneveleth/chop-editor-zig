const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Cursor = @import("cursor.zig").Cursor;
const CursorSet = @import("cursor_set.zig").CursorSet;
const CursorPool = @import("cursor_set.zig").CursorPool;
const CursorPoolIdx = @import("cursor_set.zig").CursorPoolIdx;

/// Index into UndoHistory.nodes[].
pub const UndoNodeIdx = enum(u32) { null_node = std.math.maxInt(u32), _ };
/// Index into UndoHistory.ops[].
pub const UndoOpIdx = enum(u32) { _ };
/// Offset into UndoHistory.text[].
pub const UndoTextIdx = enum(u32) { _ };

/// Sentinel: "no node".
pub const NULL_NODE = UndoNodeIdx.null_node;

pub const UndoOp = struct {
    pos:        u32,
    len:        u32,
    text_start: UndoTextIdx,
    kind:       enum(u8) { insert, delete },
};

/// An undo group (one normal-mode command or one insert session).
/// cursor_start/cursor_len index into the *live* CursorPool (pre-op snapshot).
pub const UndoNode = struct {
    parent:       UndoNodeIdx,
    first_child:  UndoNodeIdx,
    next_sibling: UndoNodeIdx,
    op_start:     UndoOpIdx,
    op_count:     u32,
    cursor_start: CursorPoolIdx,
    cursor_len:   u32,
    sequence:     u32, // monotonically increasing commit order
};

pub const UndoHistory = struct {
    nodes:    std.ArrayList(UndoNode) = .{},
    ops:      std.ArrayList(UndoOp)   = .{},
    text:     std.ArrayList(u8)       = .{},
    current:  UndoNodeIdx = NULL_NODE,
    next_seq: u32         = 1,

    // In-progress frame
    recording:            bool         = false,
    pending_op_start:     UndoOpIdx    = @enumFromInt(0),
    pending_text_start:   UndoTextIdx  = @enumFromInt(0),
    pending_cursor_start: CursorPoolIdx = @enumFromInt(0),
    pending_cursor_len:   u32           = 0,

    pub fn deinit(self: *UndoHistory, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.ops.deinit(allocator);
        self.nodes.deinit(allocator);
    }

    /// Begin a new undo group.  Snapshots cursor state (via pool) for restore on undo.
    pub fn begin(self: *UndoHistory, allocator: std.mem.Allocator, cs: *const CursorSet, pool: *CursorPool) void {
        self.recording        = true;
        self.pending_op_start = @enumFromInt(self.ops.items.len);
        self.pending_text_start = @enumFromInt(self.text.items.len);
        if (pool.snapshotRange(allocator, cs.start, cs.len)) |snap_start| {
            self.pending_cursor_start = snap_start;
            self.pending_cursor_len   = cs.len;
        } else |_| {
            self.pending_cursor_start = @enumFromInt(0);
            self.pending_cursor_len   = 0;
        }
    }

    /// Commit the group.  Discards silently if no ops were recorded.
    pub fn commit(self: *UndoHistory, allocator: std.mem.Allocator) void {
        if (!self.recording) return;
        self.recording = false;
        if (self.ops.items.len == @intFromEnum(self.pending_op_start)) return;

        const node_idx: UndoNodeIdx = @enumFromInt(self.nodes.items.len);
        var node = UndoNode{
            .parent       = self.current,
            .first_child  = NULL_NODE,
            .next_sibling = NULL_NODE,
            .op_start     = self.pending_op_start,
            .op_count     = @intCast(self.ops.items.len - @intFromEnum(self.pending_op_start)),
            .cursor_start = self.pending_cursor_start,
            .cursor_len   = self.pending_cursor_len,
            .sequence     = self.next_seq,
        };
        self.next_seq += 1;

        if (self.current != NULL_NODE) {
            node.next_sibling = self.nodes.items[@intFromEnum(self.current)].first_child;
            self.nodes.items[@intFromEnum(self.current)].first_child = node_idx;
        }

        self.nodes.append(allocator, node) catch {
            // OOM: roll back pending ops and text.
            self.ops.items  = self.ops.items[0..@intFromEnum(self.pending_op_start)];
            self.text.items = self.text.items[0..@intFromEnum(self.pending_text_start)];
            return;
        };
        self.current = node_idx;
    }

    /// Discard the in-progress group without committing.
    pub fn abort(self: *UndoHistory) void {
        if (!self.recording) return;
        self.recording  = false;
        self.ops.items  = self.ops.items[0..@intFromEnum(self.pending_op_start)];
        self.text.items = self.text.items[0..@intFromEnum(self.pending_text_start)];
    }

    /// Record an insertion; stores the inserted text so it can be replayed on redo.
    pub fn recordInsert(self: *UndoHistory, allocator: std.mem.Allocator, pos: usize, text: []const u8) void {
        if (!self.recording) return;
        const text_start: UndoTextIdx = @enumFromInt(self.text.items.len);
        self.text.appendSlice(allocator, text) catch return;
        self.ops.append(allocator, .{
            .pos        = @intCast(pos),
            .len        = @intCast(text.len),
            .text_start = text_start,
            .kind       = .insert,
        }) catch {
            self.text.items = self.text.items[0..@intFromEnum(text_start)];
        };
    }

    pub fn recordDelete(self: *UndoHistory, allocator: std.mem.Allocator, pos: usize, bytes: []const u8) void {
        if (!self.recording) return;
        const text_start: UndoTextIdx = @enumFromInt(self.text.items.len);
        self.text.appendSlice(allocator, bytes) catch return;
        self.ops.append(allocator, .{
            .pos        = @intCast(pos),
            .len        = @intCast(bytes.len),
            .text_start = text_start,
            .kind       = .delete,
        }) catch {
            self.text.items = self.text.items[0..@intFromEnum(text_start)];
        };
    }

    pub fn canUndo(self: *const UndoHistory) bool {
        return self.current != NULL_NODE;
    }

    /// Redo the most recently committed child of the current node.
    /// When current is NULL_NODE (initial state), redoes the most recently
    /// committed top-level node.
    pub fn redo(self: *UndoHistory, buf: *Buffer, cs: *CursorSet, pool: *CursorPool) void {
        const child = if (self.current != NULL_NODE)
            self.nodes.items[@intFromEnum(self.current)].first_child
        else blk: {
            // Find the node with parent=NULL_NODE that was committed most recently.
            var best = NULL_NODE;
            var best_seq: u32 = 0;
            for (self.nodes.items, 0..) |node, i| {
                if (node.parent == NULL_NODE and node.sequence > best_seq) {
                    best_seq = node.sequence;
                    best = @enumFromInt(i);
                }
            }
            break :blk best;
        };
        if (child == NULL_NODE) return;
        self.redoNode(buf, cs, pool, child);
    }

    /// Reverse the current node's ops on `buf`, restore its cursors into `cs`
    /// via the shared pool, then move `current` to the parent node.
    pub fn undo(self: *UndoHistory, buf: *Buffer, cs: *CursorSet, pool: *CursorPool) void {
        if (self.current == NULL_NODE) return;
        const node = &self.nodes.items[@intFromEnum(self.current)];
        const op_end = @intFromEnum(node.op_start) + node.op_count;
        var i = op_end;
        while (i > @intFromEnum(node.op_start)) {
            i -= 1;
            const op = self.ops.items[i];
            switch (op.kind) {
                .insert => buf.delete(op.pos, op.len) catch {},
                .delete => buf.insert(
                    op.pos,
                    self.text.items[@intFromEnum(op.text_start) .. @intFromEnum(op.text_start) + op.len],
                ) catch {},
            }
        }
        cs.restoreFrom(pool, node.cursor_start, node.cursor_len);
        self.current = node.parent;
    }

    /// Apply a node's ops in forward order (used when redoing after a branch switch).
    /// Restores the node's pre-op cursor snapshot and advances `current` to node_idx.
    fn redoNode(self: *UndoHistory, buf: *Buffer, cs: *CursorSet, pool: *CursorPool, node_idx: UndoNodeIdx) void {
        const node = &self.nodes.items[@intFromEnum(node_idx)];
        const op_start = @intFromEnum(node.op_start);
        const op_end   = op_start + node.op_count;
        for (self.ops.items[op_start..op_end]) |op| {
            switch (op.kind) {
                .insert => buf.insert(
                    op.pos,
                    self.text.items[@intFromEnum(op.text_start) .. @intFromEnum(op.text_start) + op.len],
                ) catch {},
                .delete => buf.delete(op.pos, op.len) catch {},
            }
        }
        cs.restoreFrom(pool, node.cursor_start, node.cursor_len);
        self.current = node_idx;
    }

    /// Walk the undo tree to reach `target` (may be NULL_NODE for initial state).
    /// Finds the lowest common ancestor of `current` and `target`, undoes to it,
    /// then redoes down to `target`.
    fn navigateTo(self: *UndoHistory, buf: *Buffer, cs: *CursorSet, pool: *CursorPool, target: UndoNodeIdx) void {
        if (self.current == target) return;

        // Collect ancestor chain of current (including NULL_NODE sentinel at end).
        var cur_path: [1024]UndoNodeIdx = undefined;
        var cur_len: usize = 0;
        {
            var n = self.current;
            while (cur_len < cur_path.len) {
                cur_path[cur_len] = n;
                cur_len += 1;
                if (n == NULL_NODE) break;
                n = self.nodes.items[@intFromEnum(n)].parent;
            }
        }

        // Walk up from target collecting the path down; stop at the LCA.
        var path_down: [1024]UndoNodeIdx = undefined;
        var path_down_len: usize = 0;
        var lca = NULL_NODE;
        outer: {
            var n = target;
            while (path_down_len < path_down.len) {
                for (cur_path[0..cur_len]) |a| {
                    if (a == n) { lca = n; break :outer; }
                }
                path_down[path_down_len] = n;
                path_down_len += 1;
                if (n == NULL_NODE) break; // shouldn't happen; NULL_NODE is always in cur_path
                n = self.nodes.items[@intFromEnum(n)].parent;
            }
        }

        // Undo from current up to lca.
        while (self.current != lca) self.undo(buf, cs, pool);

        // Redo from lca down to target (path_down is stored target→lca, so iterate in reverse).
        var i = path_down_len;
        while (i > 0) { i -= 1; self.redoNode(buf, cs, pool, path_down[i]); }
    }

    /// Move to the most recent commit older than the current one (alt+u).
    pub fn undoOlder(self: *UndoHistory, buf: *Buffer, cs: *CursorSet, pool: *CursorPool) void {
        if (self.current == NULL_NODE) return;
        const cur_seq = self.nodes.items[@intFromEnum(self.current)].sequence;

        var target = NULL_NODE; // default: go to initial state (before all commits)
        var best_seq: u32 = 0;
        for (self.nodes.items, 0..) |node, i| {
            if (node.sequence < cur_seq and node.sequence > best_seq) {
                best_seq = node.sequence;
                target = @enumFromInt(i);
            }
        }
        self.navigateTo(buf, cs, pool, target);
    }

    /// Move to the most recent commit newer than the current one (alt+U).
    pub fn undoNewer(self: *UndoHistory, buf: *Buffer, cs: *CursorSet, pool: *CursorPool) void {
        const cur_seq: u32 = if (self.current == NULL_NODE) 0
                             else self.nodes.items[@intFromEnum(self.current)].sequence;

        var target = NULL_NODE;
        var best_seq: u32 = std.math.maxInt(u32);
        for (self.nodes.items, 0..) |node, i| {
            if (node.sequence > cur_seq and node.sequence < best_seq) {
                best_seq = node.sequence;
                target = @enumFromInt(i);
            }
        }
        if (target == NULL_NODE) return; // already at newest
        self.navigateTo(buf, cs, pool, target);
    }
};
