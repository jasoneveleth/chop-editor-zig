const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Cursor = @import("cursor.zig").Cursor;
const CursorSet = @import("cursor_set.zig").CursorSet;
const CursorPool = @import("cursor_set.zig").CursorPool;

/// Sentinel: "no node".
pub const NULL_NODE: u32 = std.math.maxInt(u32);

pub const UndoOp = struct {
    pos:        u32,
    len:        u32,
    text_start: u32, // only meaningful for delete ops, an offset into UndoHistory.text
    kind:       enum(u8) { insert, delete },
};

/// An undo group (one normal-mode command or one insert session).
/// cursor_start/cursor_len index into the *live* CursorPool (pre-op snapshot).
pub const UndoNode = struct {
    parent:       u32,
    first_child:  u32,
    next_sibling: u32,
    op_start:     u32,
    op_count:     u32,
    cursor_start: u32,
    cursor_len:   u32,
};

pub const UndoHistory = struct {
    nodes:   std.ArrayList(UndoNode) = .{},
    ops:     std.ArrayList(UndoOp)   = .{},
    text:    std.ArrayList(u8)       = .{},
    current: u32 = NULL_NODE,

    // In-progress frame
    recording:            bool = false,
    pending_op_start:     u32  = 0,
    pending_text_start:   u32  = 0,
    pending_cursor_start: u32  = 0,
    pending_cursor_len:   u32  = 0,

    pub fn deinit(self: *UndoHistory, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.ops.deinit(allocator);
        self.nodes.deinit(allocator);
    }

    /// Begin a new undo group.  Snapshots cursor state (via pool) for restore on undo.
    pub fn begin(self: *UndoHistory, allocator: std.mem.Allocator, cs: *const CursorSet, pool: *CursorPool) void {
        self.recording        = true;
        self.pending_op_start = @intCast(self.ops.items.len);
        self.pending_text_start = @intCast(self.text.items.len);
        if (pool.snapshotRange(allocator, cs.start, cs.len)) |snap_start| {
            self.pending_cursor_start = snap_start;
            self.pending_cursor_len   = cs.len;
        } else |_| {
            self.pending_cursor_start = 0;
            self.pending_cursor_len   = 0;
        }
    }

    /// Commit the group.  Discards silently if no ops were recorded.
    pub fn commit(self: *UndoHistory, allocator: std.mem.Allocator) void {
        if (!self.recording) return;
        self.recording = false;
        if (self.ops.items.len == @as(usize, self.pending_op_start)) return;

        const node_idx: u32 = @intCast(self.nodes.items.len);
        var node = UndoNode{
            .parent       = self.current,
            .first_child  = NULL_NODE,
            .next_sibling = NULL_NODE,
            .op_start     = self.pending_op_start,
            .op_count     = @intCast(self.ops.items.len - self.pending_op_start),
            .cursor_start = self.pending_cursor_start,
            .cursor_len   = self.pending_cursor_len,
        };

        if (self.current != NULL_NODE) {
            node.next_sibling = self.nodes.items[self.current].first_child;
            self.nodes.items[self.current].first_child = node_idx;
        }

        self.nodes.append(allocator, node) catch {
            // OOM: roll back pending ops and text.
            self.ops.items  = self.ops.items[0..self.pending_op_start];
            self.text.items = self.text.items[0..self.pending_text_start];
            return;
        };
        self.current = node_idx;
    }

    /// Discard the in-progress group without committing.
    pub fn abort(self: *UndoHistory) void {
        if (!self.recording) return;
        self.recording  = false;
        self.ops.items  = self.ops.items[0..self.pending_op_start];
        self.text.items = self.text.items[0..self.pending_text_start];
    }

    pub fn recordInsert(self: *UndoHistory, allocator: std.mem.Allocator, pos: usize, len: usize) void {
        if (!self.recording) return;
        self.ops.append(allocator, .{
            .pos        = @intCast(pos),
            .len        = @intCast(len),
            .text_start = 0,
            .kind       = .insert,
        }) catch {};
    }

    pub fn recordDelete(self: *UndoHistory, allocator: std.mem.Allocator, pos: usize, bytes: []const u8) void {
        if (!self.recording) return;
        const text_start: u32 = @intCast(self.text.items.len);
        self.text.appendSlice(allocator, bytes) catch return;
        self.ops.append(allocator, .{
            .pos        = @intCast(pos),
            .len        = @intCast(bytes.len),
            .text_start = text_start,
            .kind       = .delete,
        }) catch {
            self.text.items = self.text.items[0..text_start];
        };
    }

    pub fn canUndo(self: *const UndoHistory) bool {
        return self.current != NULL_NODE;
    }

    /// Reverse the current node's ops on `buf`, restore its cursors into `cs`
    /// via the shared pool, then move `current` to the parent node.
    pub fn undo(self: *UndoHistory, buf: *Buffer, cs: *CursorSet, pool: *CursorPool) void {
        if (self.current == NULL_NODE) return;
        const node = &self.nodes.items[self.current];
        const op_end = node.op_start + node.op_count;
        var i = op_end;
        while (i > node.op_start) {
            i -= 1;
            const op = self.ops.items[i];
            switch (op.kind) {
                .insert => buf.delete(op.pos, op.len),
                .delete => buf.insert(
                    op.pos,
                    self.text.items[op.text_start .. op.text_start + op.len],
                ) catch {},
            }
        }
        cs.restoreFrom(pool, node.cursor_start, node.cursor_len);
        self.current = node.parent;
    }
};
