const std = @import("std");
const platform = @import("platform/web.zig");
const CursorSet = @import("cursor_set.zig").CursorSet;
const CursorPool = @import("cursor_set.zig").CursorPool;
const CursorPoolIdx = @import("cursor_set.zig").CursorPoolIdx;

pub const BufferId = packed struct(u32) {
    index: u24,
    generation: u8,
};

// ── Text ──────────────────────────────────────────────────────────────────────
// Raw content + line table. No undo, no stored allocator.

pub const Text = struct {
    content:     std.ArrayListUnmanaged(u8)    = .{},
    line_starts: std.ArrayListUnmanaged(usize) = .{},

    pub fn init(allocator: std.mem.Allocator) !Text {
        var self = Text{};
        try self.line_starts.append(allocator, 0);
        return self;
    }

    pub fn deinit(self: *Text, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
        self.line_starts.deinit(allocator);
    }

    pub fn len(self: *const Text) usize {
        return self.content.items.len;
    }

    pub fn insert(self: *Text, allocator: std.mem.Allocator, pos: usize, text: []const u8) !void {
        try self.content.insertSlice(allocator, pos, text);
        try self.rebuildLineTable(allocator);
    }

    pub fn delete(self: *Text, allocator: std.mem.Allocator, pos: usize, count: usize) !void {
        const end = @min(pos + count, self.content.items.len);
        self.content.replaceRangeAssumeCapacity(pos, end - pos, &.{});
        try self.rebuildLineTable(allocator);
    }

    pub fn bytes(self: *const Text) []const u8 {
        return self.content.items;
    }

    pub fn slice(self: *const Text, start: usize, end: usize) []const u8 {
        return self.content.items[start..end];
    }

    fn rebuildLineTable(self: *Text, allocator: std.mem.Allocator) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(allocator, 0);
        for (self.content.items, 0..) |c, i| {
            if (c == '\n') try self.line_starts.append(allocator, i + 1);
        }
    }

    pub fn lineStarts(self: *const Text) []const usize {
        return self.line_starts.items;
    }

    pub fn lineCount(self: *const Text) usize {
        return self.line_starts.items.len;
    }

    /// Binary search: byte offset → line number.
    pub fn lineAt(self: *const Text, byte: usize) usize {
        const ls = self.line_starts.items;
        var lo: usize = 0;
        var hi: usize = ls.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (ls[mid] <= byte) lo = mid else hi = mid;
        }
        return lo;
    }
};

// ── UndoHistory ───────────────────────────────────────────────────────────────

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
    nodes:    std.ArrayListUnmanaged(UndoNode) = .{},
    ops:      std.ArrayListUnmanaged(UndoOp)   = .{},
    text:     std.ArrayListUnmanaged(u8)       = .{},
    current:  UndoNodeIdx = NULL_NODE,
    next_seq: u32         = 1,

    // In-progress frame
    recording:            bool          = false,
    pending_op_start:     UndoOpIdx     = @enumFromInt(0),
    pending_text_start:   UndoTextIdx   = @enumFromInt(0),
    pending_cursor_start: CursorPoolIdx = @enumFromInt(0),
    pending_cursor_len:   u32           = 0,

    // Persistent navigation state for alt+u / alt+U.
    nav_target:    ?UndoNodeIdx          = null,
    nav_origin:    ?UndoNodeIdx          = null,
    nav_direction: enum { older, newer } = .older,

    pub fn deinit(self: *UndoHistory, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.ops.deinit(allocator);
        self.nodes.deinit(allocator);
    }

    /// Begin a new undo group, snapshotting cursor state for restore on undo.
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

    /// Commit the group. Discards silently if no ops were recorded.
    pub fn commit(self: *UndoHistory, allocator: std.mem.Allocator) void {
        if (!self.recording) return;
        self.recording = false;
        if (self.ops.items.len == @intFromEnum(self.pending_op_start)) return;

        self.nav_target = null;
        self.nav_origin = null;

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

    /// Record an insertion so it can be replayed on redo.
    pub fn recordInsert(self: *UndoHistory, allocator: std.mem.Allocator, pos: usize, bytes: []const u8) void {
        if (!self.recording) return;
        const text_start: UndoTextIdx = @enumFromInt(self.text.items.len);
        self.text.appendSlice(allocator, bytes) catch return;
        self.ops.append(allocator, .{
            .pos        = @intCast(pos),
            .len        = @intCast(bytes.len),
            .text_start = text_start,
            .kind       = .insert,
        }) catch {
            self.text.items = self.text.items[0..@intFromEnum(text_start)];
        };
    }

    pub fn recordDelete(self: *UndoHistory, allocator: std.mem.Allocator, pos: usize, deleted: []const u8) void {
        if (!self.recording) return;
        const text_start: UndoTextIdx = @enumFromInt(self.text.items.len);
        self.text.appendSlice(allocator, deleted) catch return;
        self.ops.append(allocator, .{
            .pos        = @intCast(pos),
            .len        = @intCast(deleted.len),
            .text_start = text_start,
            .kind       = .delete,
        }) catch {
            self.text.items = self.text.items[0..@intFromEnum(text_start)];
        };
    }

    pub fn canUndo(self: *const UndoHistory) bool {
        return self.current != NULL_NODE;
    }

    pub fn undo(self: *UndoHistory, text: *Text, allocator: std.mem.Allocator, cs: *CursorSet, pool: *CursorPool) void {
        self.nav_target = null;
        self.nav_origin = null;
        self.undoOne(text, allocator, cs, pool);
    }

    pub fn redo(self: *UndoHistory, text: *Text, allocator: std.mem.Allocator, cs: *CursorSet, pool: *CursorPool) void {
        self.nav_target = null;
        self.nav_origin = null;
        const child = if (self.current != NULL_NODE)
            self.nodes.items[@intFromEnum(self.current)].first_child
        else blk: {
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
        self.redoNode(text, allocator, cs, pool, child);
    }

    fn undoOne(self: *UndoHistory, text: *Text, allocator: std.mem.Allocator, cs: *CursorSet, pool: *CursorPool) void {
        if (self.current == NULL_NODE) return;
        const node = &self.nodes.items[@intFromEnum(self.current)];
        const op_end = @intFromEnum(node.op_start) + node.op_count;
        var i = op_end;
        while (i > @intFromEnum(node.op_start)) {
            i -= 1;
            const op = self.ops.items[i];
            switch (op.kind) {
                .insert => text.delete(allocator, op.pos, op.len) catch {},
                .delete => text.insert(
                    allocator,
                    op.pos,
                    self.text.items[@intFromEnum(op.text_start) .. @intFromEnum(op.text_start) + op.len],
                ) catch {},
            }
        }
        cs.restoreFrom(pool, node.cursor_start, node.cursor_len);
        self.current = node.parent;
    }

    fn redoNode(self: *UndoHistory, text: *Text, allocator: std.mem.Allocator, cs: *CursorSet, pool: *CursorPool, node_idx: UndoNodeIdx) void {
        const node = &self.nodes.items[@intFromEnum(node_idx)];
        const op_start = @intFromEnum(node.op_start);
        const op_end   = op_start + node.op_count;
        cs.restoreFrom(pool, node.cursor_start, node.cursor_len);
        for (self.ops.items[op_start..op_end]) |op| {
            switch (op.kind) {
                .insert => {
                    text.insert(
                        allocator,
                        op.pos,
                        self.text.items[@intFromEnum(op.text_start) .. @intFromEnum(op.text_start) + op.len],
                    ) catch {};
                    cs.adjustForInsert(pool, op.pos, op.len);
                },
                .delete => {
                    text.delete(allocator, op.pos, op.len) catch {};
                    cs.adjustForDelete(pool, op.pos, op.len);
                },
            }
        }
        self.current = node_idx;
    }

    fn stepTowards(self: *UndoHistory, text: *Text, allocator: std.mem.Allocator, cs: *CursorSet, pool: *CursorPool, target: UndoNodeIdx) void {
        if (self.current == target) return;

        var path: [1024]UndoNodeIdx = undefined;
        var path_len: usize = 0;
        var n = target;
        while (path_len < path.len) {
            if (n == self.current) {
                self.redoNode(text, allocator, cs, pool, path[path_len - 1]);
                return;
            }
            path[path_len] = n;
            path_len += 1;
            if (n == NULL_NODE) break;
            n = self.nodes.items[@intFromEnum(n)].parent;
        }

        self.undoOne(text, allocator, cs, pool);
    }

    fn logTree(self: *UndoHistory) void {
        platform.log("--- undo tree (current={}) ---", .{@intFromEnum(self.current)});
        self.logSubtree(NULL_NODE, 0);
    }

    fn logSubtree(self: *UndoHistory, parent: UndoNodeIdx, depth: usize) void {
        var children: [64]UndoNodeIdx = undefined;
        var nchildren: usize = 0;
        var sib: UndoNodeIdx = if (parent == NULL_NODE) blk: {
            var best = NULL_NODE;
            var best_seq: u32 = std.math.maxInt(u32);
            for (self.nodes.items, 0..) |node, i| {
                if (node.parent == NULL_NODE and node.sequence < best_seq) {
                    best_seq = node.sequence;
                    best = @enumFromInt(i);
                }
            }
            break :blk best;
        } else self.nodes.items[@intFromEnum(parent)].first_child;

        while (sib != NULL_NODE and nchildren < children.len) {
            children[nchildren] = sib;
            nchildren += 1;
            sib = self.nodes.items[@intFromEnum(sib)].next_sibling;
        }

        var i = nchildren;
        while (i > 0) {
            i -= 1;
            const idx = children[i];
            const node = self.nodes.items[@intFromEnum(idx)];
            const marker: u8 = if (idx == self.current) '*' else ' ';
            var indent_buf: [32]u8 = undefined;
            const indent = depth * 2;
            @memset(indent_buf[0..@min(indent, indent_buf.len)], ' ');
            platform.log("{c} {s}[{}] seq={}", .{
                marker,
                indent_buf[0..@min(indent, indent_buf.len)],
                @intFromEnum(idx),
                node.sequence,
            });
            self.logSubtree(idx, depth + 1);
        }
    }

    pub fn undoOlder(self: *UndoHistory, text: *Text, allocator: std.mem.Allocator, cs: *CursorSet, pool: *CursorPool) void {
        if (self.current == NULL_NODE) return;
        const cur_seq = self.nodes.items[@intFromEnum(self.current)].sequence;
        self.logTree();
        platform.log("undoOlder: current={} cur_seq={} nav_target={?} nav_origin={?}", .{
            @intFromEnum(self.current), cur_seq,
            if (self.nav_target) |t| @as(?u32, @intFromEnum(t)) else null,
            if (self.nav_origin) |o| @as(?u32, @intFromEnum(o)) else null,
        });

        const target: UndoNodeIdx = blk: {
            if (self.nav_target) |t| {
                if (self.nav_direction == .older and self.current != t) break :blk t;
                if (self.nav_direction == .newer) {
                    if (self.nav_origin) |orig| {
                        self.nav_origin = t;
                        self.nav_direction = .older;
                        break :blk orig;
                    }
                }
            }
            self.nav_direction = .older;
            self.nav_origin = self.current;
            var best_seq: u32 = 0;
            var best = NULL_NODE;
            for (self.nodes.items, 0..) |node, i| {
                if (node.sequence < cur_seq and node.sequence > best_seq) {
                    best_seq = node.sequence;
                    best = @enumFromInt(i);
                }
            }
            break :blk best;
        };

        self.nav_target = target;
        self.stepTowards(text, allocator, cs, pool, target);
    }

    pub fn undoNewer(self: *UndoHistory, text: *Text, allocator: std.mem.Allocator, cs: *CursorSet, pool: *CursorPool) void {
        const cur_seq: u32 = if (self.current == NULL_NODE) 0
                             else self.nodes.items[@intFromEnum(self.current)].sequence;
        platform.log("undoNewer: current={?} cur_seq={} nav_target={?} nav_origin={?}", .{
            if (self.current == NULL_NODE) null else @as(?u32, @intFromEnum(self.current)),
            cur_seq,
            if (self.nav_target) |t| @as(?u32, @intFromEnum(t)) else null,
            if (self.nav_origin) |o| @as(?u32, @intFromEnum(o)) else null,
        });

        const target: UndoNodeIdx = blk: {
            if (self.nav_target) |t| {
                if (self.nav_direction == .newer and self.current != t) break :blk t;
                if (self.nav_direction == .older) {
                    if (self.nav_origin) |orig| {
                        self.nav_origin = t;
                        self.nav_direction = .newer;
                        break :blk orig;
                    }
                }
            }
            self.nav_direction = .newer;
            self.nav_origin = self.current;
            var best_seq: u32 = std.math.maxInt(u32);
            var best = NULL_NODE;
            for (self.nodes.items, 0..) |node, i| {
                if (node.sequence > cur_seq and node.sequence < best_seq) {
                    best_seq = node.sequence;
                    best = @enumFromInt(i);
                }
            }
            break :blk best;
        };

        if (target == NULL_NODE) return;
        self.nav_target = target;
        self.stepTowards(text, allocator, cs, pool, target);
    }
};

// ── Buffer ────────────────────────────────────────────────────────────────────
// Text + its own undo history.

pub const Buffer = struct {
    text:      Text,
    history:   UndoHistory = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Buffer {
        return .{
            .text      = try Text.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.text.deinit(self.allocator);
        self.history.deinit(self.allocator);
    }

    // ── Mutations ─────────────────────────────────────────────────────────

    pub fn insert(self: *Buffer, pos: usize, text: []const u8) !void {
        try self.text.insert(self.allocator, pos, text);
    }

    pub fn delete(self: *Buffer, pos: usize, count: usize) !void {
        try self.text.delete(self.allocator, pos, count);
    }

    // ── Undo / redo wrappers ───────────────────────────────────────────────

    pub fn undo(self: *Buffer, cs: *CursorSet, pool: *CursorPool) void {
        self.history.undo(&self.text, self.allocator, cs, pool);
    }

    pub fn redo(self: *Buffer, cs: *CursorSet, pool: *CursorPool) void {
        self.history.redo(&self.text, self.allocator, cs, pool);
    }

    pub fn undoOlder(self: *Buffer, cs: *CursorSet, pool: *CursorPool) void {
        self.history.undoOlder(&self.text, self.allocator, cs, pool);
    }

    pub fn undoNewer(self: *Buffer, cs: *CursorSet, pool: *CursorPool) void {
        self.history.undoNewer(&self.text, self.allocator, cs, pool);
    }

    // ── Read-only delegates ────────────────────────────────────────────────

    pub fn len(self: *const Buffer) usize {
        return self.text.len();
    }

    pub fn bytes(self: *const Buffer) []const u8 {
        return self.text.bytes();
    }

    pub fn slice(self: *const Buffer, start: usize, end: usize) []const u8 {
        return self.text.slice(start, end);
    }

    pub fn lineStarts(self: *const Buffer) []const usize {
        return self.text.lineStarts();
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.text.lineCount();
    }

    pub fn lineAt(self: *const Buffer, byte: usize) usize {
        return self.text.lineAt(byte);
    }
};
