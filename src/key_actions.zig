/// Action functions — each has signature fn(*Editor, KeyChord) void.
/// Called by the keybind dispatch table in keybinds.zig.
const std = @import("std");
const editor = @import("editor.zig");
const Editor = editor.Editor;
const doInsert = editor.doInsert;
const doDelete = editor.doDelete;
const KeyChord = @import("key.zig").KeyChord;
const MOD_ALT = @import("key.zig").MOD_ALT;
const MOD_CTRL = @import("key.zig").MOD_CTRL;
const MOD_META = @import("key.zig").MOD_META;
const cursor_mod = @import("cursor.zig");
const grapheme = @import("grapheme.zig");
const window_mod = @import("window.zig");
const BufferView = @import("buffer_view.zig").BufferView;
const platform = @import("platform/web.zig");
const palette_mod = @import("palette.zig");
const findNextMatchFrom = palette_mod.findNextMatchFrom;
const findPrevMatchFrom = palette_mod.findPrevMatchFrom;

pub const Action = *const fn (ed: *Editor, chord: KeyChord) void;

// ── Cursor movement ────────────────────────────────────────────────────────

pub fn moveLeft(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    moveDir(ed, win, cs, .left);
}

pub fn moveRight(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    moveDir(ed, win, cs, .right);
}

pub fn moveUp(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    moveDir(ed, win, cs, .up);
}

pub fn moveDown(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    moveDir(ed, win, cs, .down);
}

pub fn collapseLeft(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.hasSelection(&ed.cursor_pool)) {
        cs.collapseToStart(&ed.cursor_pool);
    } else moveDir(ed, win, cs, .left);
}

pub fn collapseRight(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.hasSelection(&ed.cursor_pool)) {
        cs.collapseToEnd(&ed.cursor_pool);
    } else moveDir(ed, win, cs, .right);
}

pub fn extendLeft(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const content = ed.bufOf(win.buffer_id).bytes();
    win.preferred_col = null;
    for (cs.iter(&ed.cursor_pool)) |*c| c.head = cursor_mod.cursorLeft(content, c.head);
}

pub fn extendRight(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const content = ed.bufOf(win.buffer_id).bytes();
    win.preferred_col = null;
    for (cs.iter(&ed.cursor_pool)) |*c| c.head = cursor_mod.cursorRight(content, c.head);
}

pub fn wordNext(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        c.head = cursor_mod.wordNext(content, c.head);
        c.anchor = c.head;
    }
}

pub fn wordNextExtend(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        c.head = cursor_mod.wordNext(content, c.head);
    }
}

pub fn wordPrev(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        c.head = cursor_mod.wordPrev(content, c.head);
        c.anchor = c.head;
    }
}

pub fn wordPrevExtend(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        c.head = cursor_mod.wordPrev(content, c.head);
    }
}

pub fn lineStart(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        c.head = grapheme.lineStart(content, c.head);
        c.anchor = c.head;
    }
}

pub fn lineEnd(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        c.head = grapheme.findChars(content, c.head, "\n");
        c.anchor = c.head;
    }
}

pub fn lineStartExtend(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        c.head = grapheme.lineStart(content, c.head);
    }
}

pub fn lineEndExtend(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        c.head = grapheme.findChars(content, c.head, "\n");
    }
}

pub fn selectLine(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        if (grapheme.lineStart(content, c.head) == grapheme.lineStart(content, c.anchor)) {
            c.anchor = grapheme.lineStart(content, c.head);
        }
        const le = grapheme.findChars(content, c.head, "\n");
        c.head = if (le < content.len) le + 1 else content.len;
    }
}

pub fn selectLineBackward(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        if (grapheme.lineStart(content, c.head) == grapheme.lineStart(content, c.anchor)) {
            c.anchor = grapheme.findChars(content, c.head, "\n");
        }
        const cur_ls = grapheme.lineStart(content, c.head);
        c.head = if (cur_ls > 0) cur_ls - 1 else 0;
    }
}

// ── Mode transitions ───────────────────────────────────────────────────────

pub fn enterInsert(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    for (cs.iter(&ed.cursor_pool)) |*c| {
        c.anchor = c.head;
    }
    win.mode = .insert;
}

pub fn enterInsertLineStart(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        c.head = grapheme.lineStart(content, c.head);
        c.anchor = c.head;
    }
    win.mode = .insert;
}

pub fn enterInsertLineEnd(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        c.head = grapheme.findChars(content, c.head, "\n");
        c.anchor = c.head;
    }
    win.mode = .insert;
}

pub fn openLineBelow(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len == 0) return;
    const buf = ed.bufOf(win.buffer_id);
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |c| {
        const line_end = grapheme.findChars(buf.bytes(), c.head, "\n");
        doInsert(ed, win.buffer_id, line_end, "\n") catch continue;
        c.head = line_end + 1;
        c.anchor = c.head;
    }
    win.mode = .insert;
}

pub fn openLineAbove(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len == 0) return;
    const buf = ed.bufOf(win.buffer_id);
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |c| {
        const ls = grapheme.lineStart(buf.bytes(), c.head);
        doInsert(ed, win.buffer_id, ls, "\n") catch continue;
        c.head = ls;
        c.anchor = c.head;
    }
    win.mode = .insert;
}

// ── Edit operations ────────────────────────────────────────────────────────

pub fn deleteOp(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len == 0) return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    const c = cs.iter(&ed.cursor_pool)[0];
    if (c.isSelection()) {
        deleteSelections(ed, win, cs);
        cs.clearSelections(&ed.cursor_pool);
    } else {
        const ls = grapheme.lineStart(content, c.head);
        const le = grapheme.findChars(content, c.head, "\n");
        const line_end = if (le < content.len) le + 1 else content.len;
        doDelete(ed, win.buffer_id, ls, line_end - ls);
    }
}

pub fn deleteLines(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len == 0) return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    const Range = struct { start: usize, end: usize };
    const MAX_CURSORS = @import("buffer_view.zig").MAX_CURSORS;
    var ranges: [MAX_CURSORS]Range = undefined;
    for (cs.iter(&ed.cursor_pool), 0..) |c, i| {
        const ls = grapheme.lineStart(content, c.start());
        const le = grapheme.findChars(content, c.end(), "\n");
        ranges[i] = .{
            .start = ls,
            .end = if (le < content.len) le + 1 else content.len,
        };
    }
    var merged: [MAX_CURSORS]Range = undefined;
    var n: usize = 0;
    for (ranges[0..cs.len]) |r| {
        if (n > 0 and r.start <= merged[n - 1].end) {
            merged[n - 1].end = @max(merged[n - 1].end, r.end);
        } else {
            merged[n] = r;
            n += 1;
        }
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        doDelete(ed, win.buffer_id, merged[i].start, merged[i].end - merged[i].start);
    }
}

pub fn yank(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len == 0) return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    const c = cs.iter(&ed.cursor_pool)[0];
    if (c.isSelection()) {
        platform.writeClipboard(content[c.start()..c.end()]);
    } else {
        const ls = grapheme.lineStart(content, c.head);
        const le = grapheme.findChars(content, c.head, "\n");
        const line_end = if (le < content.len) le + 1 else content.len;
        platform.writeClipboard(content[ls..line_end]);
    }
}

pub fn paste(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    cs.clearSelections(&ed.cursor_pool);
    const clip = platform.readClipboard();
    if (clip.len > 0) ed.insertAtCursors(win, cs, clip);
}

pub fn cut(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len == 0) return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    const c = cs.iter(&ed.cursor_pool)[0];
    if (c.isSelection()) {
        platform.writeClipboard(content[c.start()..c.end()]);
        deleteSelections(ed, win, cs);
        cs.clearSelections(&ed.cursor_pool);
    } else {
        const ls = grapheme.lineStart(content, c.head);
        const le = grapheme.findChars(content, c.head, "\n");
        const line_end = if (le < content.len) le + 1 else content.len;
        platform.writeClipboard(content[ls..line_end]);
        doDelete(ed, win.buffer_id, ls, line_end - ls);
    }
    win.mode = .insert;
}

pub fn transposeChars(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |c| {
        const prev = cursor_mod.cursorLeft(content, c.head);
        const next = cursor_mod.cursorRight(content, c.head);
        if (prev < c.head and next > c.head) {
            const left_len = c.head - prev;
            const right_len = next - c.head;
            var left_copy: [32]u8 = undefined;
            var right_copy: [32]u8 = undefined;
            @memcpy(left_copy[0..left_len], content[prev..c.head]);
            @memcpy(right_copy[0..right_len], content[c.head..next]);
            doDelete(ed, win.buffer_id, prev, left_len + right_len);
            doInsert(ed, win.buffer_id, prev, right_copy[0..right_len]) catch {};
            doInsert(ed, win.buffer_id, prev + right_len, left_copy[0..left_len]) catch {};
            c.head = cursor_mod.cursorLeft(content, c.head);
            c.anchor = c.head;
        }
    }
}

pub fn transposeWords(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |c| {
        if (c.head == 0 or (cursor_mod.isWordChar(content[c.head]) and cursor_mod.isWordChar(content[c.head - 1]))) continue;
        var lend = c.head;
        while (lend > 0 and !cursor_mod.isWordChar(content[lend - 1])) lend -= 1;
        if (lend == 0) continue;
        var lstart = lend;
        while (lstart > 0 and cursor_mod.isWordChar(content[lstart - 1])) lstart -= 1;
        var rstart = c.head;
        while (rstart < content.len and !cursor_mod.isWordChar(content[rstart])) rstart += 1;
        if (rstart >= content.len) continue;
        var rend = rstart + 1;
        while (rend < content.len and cursor_mod.isWordChar(content[rend])) rend += 1;
        if (lend > rstart) continue;
        const lword_len = lend - lstart;
        const rword_len = rend - rstart;
        const affected_len = rend - lstart;
        if (affected_len > 256) continue;
        var affected: [256]u8 = undefined;
        @memcpy(affected[0..affected_len], content[lstart..rend]);
        const prev_head = c.head;
        doDelete(ed, win.buffer_id, lstart, affected_len);
        doInsert(ed, win.buffer_id, lstart, affected[0..lword_len]) catch {};
        doInsert(ed, win.buffer_id, lstart, affected[lend - lstart .. rstart - lstart]) catch {};
        doInsert(ed, win.buffer_id, lstart, affected[rstart - lstart .. rend - lstart]) catch {};
        c.head = (prev_head + rword_len) - lword_len;
        c.anchor = c.head;
    }
}

pub fn duplicateAfter(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len == 0) return;
    const buf = ed.bufOf(win.buffer_id);
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |c| {
        if (!c.isSelection()) continue;
        const content = buf.bytes();
        const sel_start = c.start();
        const sel_end = c.end();
        const copy = ed.allocator.dupe(u8, content[sel_start..sel_end]) catch continue;
        defer ed.allocator.free(copy);
        const orig_head = c.head;
        const orig_anchor = c.anchor;
        doInsert(ed, win.buffer_id, sel_end, copy) catch {};
        c.head = orig_head;
        c.anchor = orig_anchor;
    }
}

pub fn duplicateBefore(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len == 0) return;
    const buf = ed.bufOf(win.buffer_id);
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |c| {
        if (!c.isSelection()) continue;
        const content = buf.bytes();
        const sel_start = c.start();
        const sel_end = c.end();
        const copy = ed.allocator.dupe(u8, content[sel_start..sel_end]) catch continue;
        defer ed.allocator.free(copy);
        doInsert(ed, win.buffer_id, sel_start, copy) catch {};
    }
}

pub fn moveLineUp(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    for (cs.iter(&ed.cursor_pool)) |*c| {
        const content = buf.bytes();
        const ls = grapheme.lineStart(content, c.head);
        if (ls == 0) continue;
        const prev_le = ls - 1;
        const prev_ls = grapheme.lineStart(content, prev_le);
        const le = grapheme.findChars(content, c.head, "\n");
        const col_offset = c.head - ls;
        const la_len = le - ls;
        const lb_len = prev_le - prev_ls;
        if (la_len > 4096 or lb_len > 4096) continue;
        var line_a: [4096]u8 = undefined;
        var line_b: [4096]u8 = undefined;
        @memcpy(line_a[0..la_len], content[ls..le]);
        @memcpy(line_b[0..lb_len], content[prev_ls..prev_le]);
        doDelete(ed, win.buffer_id, prev_ls, le - prev_ls);
        doInsert(ed, win.buffer_id, prev_ls, line_a[0..la_len]) catch {};
        doInsert(ed, win.buffer_id, prev_ls + la_len, "\n") catch {};
        doInsert(ed, win.buffer_id, prev_ls + la_len + 1, line_b[0..lb_len]) catch {};
        c.head = prev_ls + @min(col_offset, la_len);
        c.anchor = c.head;
    }
}

pub fn moveLineDown(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |c| {
        const content = buf.bytes();
        const ls = grapheme.lineStart(content, c.head);
        const le = grapheme.findChars(content, c.head, "\n");
        if (le >= content.len) continue;
        const next_ls = le + 1;
        const next_le = grapheme.findChars(content, next_ls, "\n");
        const col_offset = c.head - ls;
        const la_len = le - ls;
        const lb_len = next_le - next_ls;
        if (la_len > 4096 or lb_len > 4096) continue;
        var line_a: [4096]u8 = undefined;
        var line_b: [4096]u8 = undefined;
        @memcpy(line_a[0..la_len], content[ls..le]);
        @memcpy(line_b[0..lb_len], content[next_ls..next_le]);
        doDelete(ed, win.buffer_id, ls, next_le - ls);
        doInsert(ed, win.buffer_id, ls, line_b[0..lb_len]) catch {};
        doInsert(ed, win.buffer_id, ls + lb_len, "\n") catch {};
        doInsert(ed, win.buffer_id, ls + lb_len + 1, line_a[0..la_len]) catch {};
        c.head = ls + lb_len + 1 + @min(col_offset, la_len);
        c.anchor = c.head;
    }
}

// ── Undo / redo ────────────────────────────────────────────────────────────

pub fn undoOp(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    buf.undo(cs, &ed.cursor_pool);
    win.preferred_col = null;
    ed.palette.matches_stale = true;
    ed.highlighters.items[win.buffer_id.index].rehighlight(buf.bytes()) catch {};
}

pub fn redoOp(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    buf.redo(cs, &ed.cursor_pool);
    win.preferred_col = null;
    ed.palette.matches_stale = true;
    ed.highlighters.items[win.buffer_id.index].rehighlight(buf.bytes()) catch {};
}

pub fn undoOlderOp(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    buf.undoOlder(cs, &ed.cursor_pool);
    win.preferred_col = null;
    ed.palette.matches_stale = true;
    ed.highlighters.items[win.buffer_id.index].rehighlight(buf.bytes()) catch {};
}

pub fn undoNewerOp(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    buf.undoNewer(cs, &ed.cursor_pool);
    win.preferred_col = null;
    ed.palette.matches_stale = true;
    ed.highlighters.items[win.buffer_id.index].rehighlight(buf.bytes()) catch {};
}

// ── Multi-cursor ───────────────────────────────────────────────────────────

pub fn addCursorDown(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len == 0) return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    const items = cs.iter(&ed.cursor_pool);
    const last = items[cs.len - 1];
    const ls = grapheme.lineStart(content, last.head);
    const col_px = win.preferred_col orelse platform.measureText(content[ls..last.head], win.font_size);
    win.preferred_col = col_px;
    const new_head = if (cs.softwrap)
        window_mod.cursorDownWrapped(content, last.head, col_px, win.font_size, cs.wrap_rows.items)
    else
        cursor_mod.cursorDown(content, last.head, col_px, win.font_size);
    if (new_head != last.head)
        cs.insert(&ed.cursor_pool, .{ .head = new_head, .anchor = new_head }) catch {};
}

pub fn addCursorUp(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len == 0) return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    const first = cs.iter(&ed.cursor_pool)[0];
    const ls = grapheme.lineStart(content, first.head);
    const col_px = win.preferred_col orelse platform.measureText(content[ls..first.head], win.font_size);
    win.preferred_col = col_px;
    const new_head = if (cs.softwrap)
        window_mod.cursorUpWrapped(content, first.head, col_px, win.font_size, cs.wrap_rows.items)
    else
        cursor_mod.cursorUp(content, first.head, col_px, win.font_size);
    if (new_head != first.head)
        cs.insert(&ed.cursor_pool, .{ .head = new_head, .anchor = new_head }) catch {};
}

pub fn removeCursorBottom(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len > 1) cs.len -= 1;
}

pub fn removeCursorTop(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len > 1) {
        const all = ed.cursor_pool.slice(cs.start, cs.len);
        var i: u32 = 0;
        while (i < cs.len - 1) : (i += 1) all[i] = all[i + 1];
        cs.len -= 1;
    }
}

pub fn dropToSingleCursor(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len > 1) cs.len = 1;
}

pub fn collapseSelections(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    for (cs.iter(&ed.cursor_pool)) |*c| {
        c.anchor = c.head;
    }
}

pub fn flipSelectionDirection(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    for (cs.iter(&ed.cursor_pool)) |*c| {
        const tmp = c.head;
        c.head = c.anchor;
        c.anchor = tmp;
    }
}

pub fn flipSelectionsForward(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    for (cs.iter(&ed.cursor_pool)) |*c| {
        if (c.head > c.anchor) {
            const tmp = c.head;
            c.head = c.anchor;
            c.anchor = tmp;
        }
    }
}

pub fn clearSelections(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    cs.clearSelections(&ed.cursor_pool);
}

// ── Search / match navigation ──────────────────────────────────────────────

pub fn searchForwardOp(ed: *Editor, _: KeyChord) void {
    ed.openPalette(.{ .prompt_symbol = "/", .op_kind = .search_forward, .preview = .search_highlights }) catch {};
}

pub fn searchBackwardOp(ed: *Editor, _: KeyChord) void {
    ed.openPalette(.{ .prompt_symbol = "?", .op_kind = .search_backward, .preview = .search_highlights }) catch {};
}

pub fn splitSelections(ed: *Editor, _: KeyChord) void {
    ed.openPalette(.{ .prompt_symbol = "s/", .op_kind = .split_selections, .require_selection = true, .prepopulate_selection = false }) catch {};
}

pub fn splitSelectionsComplement(ed: *Editor, _: KeyChord) void {
    ed.openPalette(.{ .prompt_symbol = "S/", .op_kind = .split_selections_complement, .require_selection = true, .prepopulate_selection = false }) catch {};
}

pub fn filterKeep(ed: *Editor, _: KeyChord) void {
    ed.openPalette(.{ .prompt_symbol = "v/", .op_kind = .filter_keep, .require_selection = true, .prepopulate_selection = false }) catch {};
}

pub fn filterDrop(ed: *Editor, _: KeyChord) void {
    ed.openPalette(.{ .prompt_symbol = "V/", .op_kind = .filter_drop, .require_selection = true, .prepopulate_selection = false }) catch {};
}

pub fn nextMatch(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    ed.requireFreshMatches();
    if (ed.palette.matches.items.len == 0 or cs.len == 0) return;
    const m = findNextMatchFrom(ed.palette.matches.items, cs.iter(&ed.cursor_pool)[cs.len - 1].end()) orelse return;
    cs.clear();
    cs.insert(&ed.cursor_pool, .{ .head = m.end, .anchor = m.start }) catch {};
}

pub fn nextMatchAdd(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    ed.requireFreshMatches();
    if (ed.palette.matches.items.len == 0 or cs.len == 0) return;
    const m = findNextMatchFrom(ed.palette.matches.items, cs.iter(&ed.cursor_pool)[cs.len - 1].end()) orelse return;
    cs.insert(&ed.cursor_pool, .{ .head = m.end, .anchor = m.start }) catch {};
}

pub fn prevMatch(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    ed.requireFreshMatches();
    if (ed.palette.matches.items.len == 0 or cs.len == 0) return;
    const m = findPrevMatchFrom(ed.palette.matches.items, cs.iter(&ed.cursor_pool)[0].start()) orelse return;
    cs.clear();
    cs.insert(&ed.cursor_pool, .{ .head = m.end, .anchor = m.start }) catch {};
}

pub fn prevMatchAdd(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    ed.requireFreshMatches();
    if (ed.palette.matches.items.len == 0 or cs.len == 0) return;
    const m = findPrevMatchFrom(ed.palette.matches.items, cs.iter(&ed.cursor_pool)[0].start()) orelse return;
    cs.insert(&ed.cursor_pool, .{ .head = m.end, .anchor = m.start }) catch {};
}

pub fn selectAllMatches(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    if (cs.len == 0) return;
    ed.requireFreshMatches();
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    if (ed.palette.matches.items.len == 0) {
        const c0 = cs.iter(&ed.cursor_pool)[0];
        const term: ?[]const u8 = if (c0.isSelection())
            content[c0.start()..c0.end()]
        else if (cursor_mod.wordBoundsAt(content, c0.head)) |wb|
            content[wb.start..wb.end]
        else
            null;
        if (term) |word| {
            ed.palette.input.setText(word);
            ed.palette.matches_stale = true;
            ed.updateMatches() catch return;
        }
    }
    if (ed.palette.matches.items.len > 0) {
        cs.clear();
        for (ed.palette.matches.items) |m| {
            cs.insert(&ed.cursor_pool, .{ .head = m.end, .anchor = m.start }) catch break;
        }
    }
}

// ── Settings palette ───────────────────────────────────────────────────────

pub fn openSettings(ed: *Editor, _: KeyChord) void {
    ed.openPalette(.{ .prompt_symbol = ":", .op_kind = .picker, .prepopulate_selection = false, .picker_items = &palette_mod.SETTINGS_ITEMS }) catch {};
}

// ── Pending key handlers ───────────────────────────────────────────────────
// These are called from Window.pending_key_handler when waiting for a second key.

pub fn pendingG(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    switch (chord.key) {
        'k' => {
            const first_line_end = grapheme.findChars(content, 0, "\n");
            for (cs.iter(&ed.cursor_pool)) |*c| {
                const ls = grapheme.lineStart(content, c.head);
                const col_px = win.preferred_col orelse platform.measureText(content[ls..c.head], win.font_size);
                win.preferred_col = col_px;
                c.head = cursor_mod.closestPosToX(content, 0, first_line_end, col_px, win.font_size);
                c.anchor = c.head;
            }
        },
        'j' => {
            var last_ls: usize = 0;
            for (content, 0..) |ch, i| {
                if (ch == '\n') last_ls = i + 1;
            }
            for (cs.iter(&ed.cursor_pool)) |*c| {
                const ls = grapheme.lineStart(content, c.head);
                const col_px = win.preferred_col orelse platform.measureText(content[ls..c.head], win.font_size);
                win.preferred_col = col_px;
                c.head = cursor_mod.closestPosToX(content, last_ls, content.len, col_px, win.font_size);
                c.anchor = c.head;
            }
        },
        'h' => platform.openUrl("https://jason.pub/chop-editor-zig/keyboard-guide.html"),
        else => {},
    }
}

pub fn pendingA(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    switch (chord.key) {
        'w' => {
            for (cs.iter(&ed.cursor_pool)) |*c| {
                if (cursor_mod.wordBoundsAt(content, c.head)) |wb| {
                    c.anchor = wb.start;
                    c.head = wb.end;
                }
            }
        },
        '\'' => {
            for (cs.iter(&ed.cursor_pool)) |*c| {
                if (cursor_mod.quoteBounds(content, c.head, '\'')) |qb| {
                    c.anchor = qb.start + 1;
                    c.head = qb.end;
                }
            }
        },
        '(', ')' => {
            for (cs.iter(&ed.cursor_pool)) |*c| {
                if (cursor_mod.parenBounds(content, c.head, '(', ')')) |pb| {
                    c.anchor = pb.start + 1;
                    c.head = pb.end;
                }
            }
        },
        'p' => {
            for (cs.iter(&ed.cursor_pool)) |*c| {
                var s = grapheme.lineStart(content, c.head);
                while (s > 0) {
                    const prev_le = s - 1;
                    const prev_ls = grapheme.lineStart(content, prev_le);
                    if (prev_ls == prev_le) break;
                    s = prev_ls;
                }
                var e = c.head;
                while (e < content.len) {
                    const le = grapheme.findChars(content, e, "\n");
                    if (le == grapheme.lineStart(content, e)) break;
                    e = if (le < content.len) le + 1 else content.len;
                }
                c.anchor = s;
                c.head = e;
            }
        },
        'e' => {
            if (cs.len > 0) {
                const items = cs.iter(&ed.cursor_pool);
                items[0].anchor = 0;
                items[0].head = content.len;
                cs.len = 1;
            }
        },
        else => {},
    }
}

pub fn pendingAUpper(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    switch (chord.key) {
        '\'' => {
            for (cs.iter(&ed.cursor_pool)) |*c| {
                if (cursor_mod.quoteBounds(content, c.head, '\'')) |qb| {
                    c.anchor = qb.start;
                    c.head = qb.end + 1;
                }
            }
        },
        else => {},
    }
}

pub fn pendingCUpper(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    switch (chord.key) {
        'd' => {
            if (cs.len > 1) cs.len = 1;
        },
        'v' => {
            for (cs.iter(&ed.cursor_pool)) |*c| {
                c.anchor = c.head;
            }
        },
        'c' => {
            for (cs.iter(&ed.cursor_pool)) |*c| {
                const tmp = c.head;
                c.head = c.anchor;
                c.anchor = tmp;
            }
        },
        'C' => {
            for (cs.iter(&ed.cursor_pool)) |*c| {
                if (c.head > c.anchor) {
                    const tmp = c.head;
                    c.head = c.anchor;
                    c.anchor = tmp;
                }
            }
        },
        else => {},
    }
}

pub fn pendingQuote(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    switch (chord.key) {
        'j' => {
            const items = cs.iter(&ed.cursor_pool);
            const ls = grapheme.lineStart(content, items[0].head);
            const col_px = win.preferred_col orelse platform.measureText(content[ls..items[0].head], win.font_size);
            win.preferred_col = col_px;
            const rows = cs.wrap_rows.items;
            for (items) |*c| {
                c.head = if (cs.softwrap)
                    window_mod.cursorDownWrapped(content, c.head, col_px, win.font_size, rows)
                else
                    cursor_mod.cursorDown(content, c.head, col_px, win.font_size);
            }
        },
        'k' => {
            const items = cs.iter(&ed.cursor_pool);
            const ls = grapheme.lineStart(content, items[0].head);
            const col_px = win.preferred_col orelse platform.measureText(content[ls..items[0].head], win.font_size);
            win.preferred_col = col_px;
            const rows = cs.wrap_rows.items;
            for (items) |*c| {
                c.head = if (cs.softwrap)
                    window_mod.cursorUpWrapped(content, c.head, col_px, win.font_size, rows)
                else
                    cursor_mod.cursorUp(content, c.head, col_px, win.font_size);
            }
        },
        else => {},
    }
}

pub fn pendingM(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    switch (chord.key) {
        's' => {
            win.pending_key_handler = pendingSurround;
        },
        'd' => {
            win.pending_key_handler = pendingDeleteSurround;
        },
        'r' => {
            win.pending_key_handler = pendingReplaceSurround1;
        },
        else => {},
    }
}

pub fn pendingSurround(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.pending_key_handler = null;
    const pair = cursor_mod.surroundPair(@intCast(chord.key));
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |c| {
        const s = c.start();
        const e = c.end();
        doInsert(ed, win.buffer_id, e, &[_]u8{pair.close}) catch continue;
        doInsert(ed, win.buffer_id, s, &[_]u8{pair.open}) catch continue;
    }
}

pub fn pendingDeleteSurround(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.pending_key_handler = null;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    const ch: u8 = @intCast(chord.key);
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |c| {
        if (cursor_mod.surroundBounds(content, c.head, ch)) |b| {
            doDelete(ed, win.buffer_id, b.end, 1);
            doDelete(ed, win.buffer_id, b.start, 1);
            c.head = b.start;
            c.anchor = b.start;
        }
    }
}

pub fn pendingReplaceSurround1(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    win.pending_char = @intCast(chord.key);
    win.pending_key_handler = pendingReplaceSurround2;
}

pub fn pendingReplaceSurround2(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const char1 = win.pending_char;
    win.pending_key_handler = null;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    const char2: u8 = @intCast(chord.key);
    const pair2 = cursor_mod.surroundPair(char2);
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |c| {
        if (cursor_mod.surroundBounds(content, c.head, char1)) |b| {
            doDelete(ed, win.buffer_id, b.end, 1);
            doInsert(ed, win.buffer_id, b.end, &[_]u8{pair2.close}) catch {};
            doDelete(ed, win.buffer_id, b.start, 1);
            doInsert(ed, win.buffer_id, b.start, &[_]u8{pair2.open}) catch {};
        }
    }
}

pub fn pendingReplaceLeft(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.pending_key_handler = null;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    const ch: u8 = @intCast(chord.key);
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |c| {
        const prev = cursor_mod.cursorLeft(content, c.head);
        if (prev < c.head) {
            doDelete(ed, win.buffer_id, prev, c.head - prev);
            doInsert(ed, win.buffer_id, prev, &[_]u8{ch}) catch {};
        }
    }
}

pub fn pendingReplaceRight(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.pending_key_handler = null;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    const ch: u8 = @intCast(chord.key);
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |c| {
        const next = cursor_mod.cursorRight(content, c.head);
        if (next > c.head) {
            doInsert(ed, win.buffer_id, next, &[_]u8{ch}) catch {};
            doDelete(ed, win.buffer_id, c.head, next - c.head);
        }
    }
}

pub fn pendingSneakFirst(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    win.pending_char = @intCast(chord.key);
    win.pending_key_handler = pendingSneakSecond;
}

pub fn pendingSneakSecond(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.pending_key_handler = null;
    const c1 = win.pending_char;
    const c2: u8 = @intCast(chord.key);
    win.sneak_c1 = c1;
    win.sneak_c2 = c2;
    win.last_cmd = if (win.sneak_forward) 'f' else 'F';
    execSneak(ed, win, cs, c1, c2, win.sneak_forward);
}

// ── Normal-mode actions (previously inline in onKeyDown) ───────────────────

pub fn normalEscape(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    win.pending_key_handler = null;
    win.preferred_col = null;
}

pub fn normalDeleteBack(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.preferred_col = null;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |cursor| {
        const prev = cursor_mod.cursorLeft(content, cursor.head);
        if (prev < cursor.head)
            doDelete(ed, win.buffer_id, prev, cursor.head - prev);
    }
}

pub fn normalDeleteForward(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.preferred_col = null;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |cursor| {
        const next = cursor_mod.cursorRight(content, cursor.head);
        if (next > cursor.head)
            doDelete(ed, win.buffer_id, cursor.head, next - cursor.head);
    }
}

pub fn pendingPrefixSetup(ed: *Editor, chord: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    win.last_cmd = @intCast(chord.key);
    win.preferred_col = null;
    win.pending_key_handler = switch (chord.key) {
        'g' => pendingG,
        'a' => pendingA,
        'A' => pendingAUpper,
        'C' => pendingCUpper,
        '"' => pendingQuote,
        'm' => pendingM,
        else => return,
    };
}

pub fn replaceLeftSetup(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    win.last_cmd = 'r';
    win.preferred_col = null;
    win.pending_key_handler = pendingReplaceLeft;
}

pub fn replaceRightSetup(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    win.last_cmd = 'R';
    win.preferred_col = null;
    win.pending_key_handler = pendingReplaceRight;
}

pub fn sneakForwardSetup(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const prev_cmd = win.last_cmd;
    win.last_cmd = 'f';
    win.preferred_col = null;
    if (prev_cmd == 'f' or prev_cmd == 'F') {
        execSneak(ed, win, cs, win.sneak_c1, win.sneak_c2, win.sneak_forward);
    } else {
        win.sneak_forward = true;
        win.pending_key_handler = pendingSneakFirst;
    }
}

pub fn sneakBackwardSetup(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    const prev_cmd = win.last_cmd;
    win.last_cmd = 'F';
    win.preferred_col = null;
    if (prev_cmd == 'f' or prev_cmd == 'F') {
        execSneak(ed, win, cs, win.sneak_c1, win.sneak_c2, !win.sneak_forward);
    } else {
        win.sneak_forward = false;
        win.pending_key_handler = pendingSneakFirst;
    }
}

// ── Insert-mode actions ────────────────────────────────────────────────────

pub fn selfInsert(ed: *Editor, chord: KeyChord) void {
    if (chord.key > 0x10FFFF) return;
    if (chord.hasMod(MOD_CTRL) or chord.hasMod(MOD_META)) return;
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.preferred_col = null;
    var encoded: [4]u8 = undefined;
    const cp: u21 = @intCast(chord.key);
    const byte_len = std.unicode.utf8Encode(cp, &encoded) catch return;
    ed.insertAtCursors(win, cs, encoded[0..byte_len]);
}

pub fn insertEscape(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    ed.bufOf(win.buffer_id).history.commit(ed.allocator);
    win.mode = .normal;
    win.preferred_col = null;
}

pub fn insertBackspace(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.preferred_col = null;
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |cursor| {
        if (cursor.head > 0)
            doDelete(ed, win.buffer_id, cursor.head - 1, 1);
    }
}

pub fn insertEnter(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.preferred_col = null;
    ed.insertAtCursors(win, cs, "\n");
}

pub fn insertTab(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.preferred_col = null;
    ed.insertAtCursors(win, cs, "        "[0..ed.tab_width]);
}

pub fn insertPaste(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.preferred_col = null;
    cs.clearSelections(&ed.cursor_pool);
    const clip = platform.readClipboard();
    if (clip.len > 0) ed.insertAtCursors(win, cs, clip);
}

pub fn insertWordDelete(ed: *Editor, _: KeyChord) void {
    const win = ed.getWindow(ed.focused_window) orelse return;
    const cs = ed.getBufferView(win.buffer_view_id) orelse return;
    win.preferred_col = null;
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |cursor| {
        const prev = cursor_mod.wordPrev(content, cursor.head);
        if (prev < cursor.head)
            doDelete(ed, win.buffer_id, prev, cursor.head - prev);
    }
}

// ── Command-mode (palette) actions ─────────────────────────────────────────

pub fn paletteEscape(ed: *Editor, _: KeyChord) void {
    ed.closePalette(false);
}

pub fn paletteEnter(ed: *Editor, _: KeyChord) void {
    ed.closePalette(true);
}

pub fn paletteBackspace(ed: *Editor, _: KeyChord) void {
    if (ed.palette.input.cursor > 0) {
        ed.palette.input.deleteBack();
        ed.palette.matches_stale = true;
        ed.palette.picker_selected = 0;
        if (ed.palette.active) |config| {
            if (config.preview == .search_highlights) {
                ed.updateMatches() catch {};
            }
        }
    }
}

pub fn paletteUp(ed: *Editor, _: KeyChord) void {
    if (ed.palette.picker_selected > 0)
        ed.palette.picker_selected -= 1;
}

pub fn paletteDown(ed: *Editor, _: KeyChord) void {
    const pat = ed.palette.input.bytes();
    var filtered_count: usize = 0;
    for (ed.palette.picker_items) |item| {
        if (palette_mod.scoreMatch(pat, item.label).tier != 255)
            filtered_count += 1;
    }
    if (filtered_count > 0 and ed.palette.picker_selected + 1 < filtered_count)
        ed.palette.picker_selected += 1;
}

pub fn paletteLeft(ed: *Editor, _: KeyChord) void {
    ed.palette.input.moveLeft();
}

pub fn paletteRight(ed: *Editor, _: KeyChord) void {
    ed.palette.input.moveRight();
}

pub fn paletteInsert(ed: *Editor, chord: KeyChord) void {
    if (chord.key > 0x10FFFF) return;
    var encoded: [4]u8 = undefined;
    const cp: u21 = @intCast(chord.key);
    const byte_len = std.unicode.utf8Encode(cp, &encoded) catch return;
    ed.palette.input.insertSlice(encoded[0..byte_len]);
    ed.palette.matches_stale = true;
    ed.palette.picker_selected = 0;
    if (ed.palette.active) |config| {
        if (config.preview == .search_highlights) {
            ed.updateMatches() catch {};
        }
    }
}

// ── Private helpers ────────────────────────────────────────────────────────

const Dir = enum { left, right, up, down };

fn moveDir(ed: *Editor, win: *window_mod.Window, cs: *BufferView, dir: Dir) void {
    const buf = ed.bufOf(win.buffer_id);
    const content = buf.bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        switch (dir) {
            .left, .right => {
                c.head = if (dir == .left) cursor_mod.cursorLeft(content, c.head) else cursor_mod.cursorRight(content, c.head);
                win.preferred_col = null;
            },
            .up, .down => {
                const ls = grapheme.lineStart(content, c.head);
                const col_px = win.preferred_col orelse platform.measureText(content[ls..c.head], win.font_size);
                win.preferred_col = col_px;
                const rows = cs.wrap_rows.items;
                c.head = if (cs.softwrap)
                    (if (dir == .up) window_mod.cursorUpWrapped(content, c.head, col_px, win.font_size, rows) else window_mod.cursorDownWrapped(content, c.head, col_px, win.font_size, rows))
                else
                    (if (dir == .up) cursor_mod.cursorUp(content, c.head, col_px, win.font_size) else cursor_mod.cursorDown(content, c.head, col_px, win.font_size));
            },
        }
        c.anchor = c.head;
    }
}

fn deleteSelections(ed: *Editor, win: *window_mod.Window, cs: *BufferView) void {
    var it = cs.reverseIter(&ed.cursor_pool);
    while (it.next()) |cursor| {
        if (cursor.isSelection())
            doDelete(ed, win.buffer_id, cursor.start(), cursor.end() - cursor.start());
    }
}

fn execSneak(ed: *Editor, win: *window_mod.Window, cs: *BufferView, c1: u8, c2: u8, forward: bool) void {
    if (c1 == 0) return;
    const content = ed.bufOf(win.buffer_id).bytes();
    for (cs.iter(&ed.cursor_pool)) |*c| {
        const result = if (forward)
            cursor_mod.sneakForward(content, c.head, c1, c2)
        else
            cursor_mod.sneakBackward(content, c.head, c1, c2);
        if (result) |pos| {
            c.head = pos;
            c.anchor = pos;
        }
    }
    win.preferred_col = null;
}
