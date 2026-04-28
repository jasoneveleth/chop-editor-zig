/// Key dispatch tables — one per editor mode.
/// Each table maps a packed KeyChord (u32) → Action.
const std = @import("std");
const Key = @import("key.zig").Key;
const KeyChord = @import("key.zig").KeyChord;
const MOD_SHIFT = @import("key.zig").MOD_SHIFT;
const MOD_CTRL = @import("key.zig").MOD_CTRL;
const MOD_ALT = @import("key.zig").MOD_ALT;
const actions = @import("actions.zig");
const Action = actions.Action;
const Mode = @import("window.zig").Mode;

/// Build a KeyChord from a Key + mods.
/// For non-alt printable chars (JS sends the shifted char already, e.g. 'W' not 'w'+SHIFT),
/// strips MOD_SHIFT so that table entries match on the character value alone.
pub fn keyChord(key: Key, mods: u32) KeyChord {
    const k: u22 = @truncate(@intFromEnum(key));
    const effective_mods: u10 = @truncate(
        if (mods & MOD_ALT == 0 and @intFromEnum(key) <= 0x10FFFF)
            mods & ~@as(u32, MOD_SHIFT)
        else
            mods,
    );
    return .{ .key = k, .mods = effective_mods };
}

/// Convenience: build a chord from a character literal + mods.
pub fn charChord(comptime ch: u8, mods: u32) KeyChord {
    return keyChord(@enumFromInt(ch), mods);
}

pub const Table = struct {
    bindings: std.AutoHashMapUnmanaged(u32, Action) = .{},
    default_action: ?Action = null,

    pub fn put(self: *Table, allocator: std.mem.Allocator, chord: KeyChord, action: Action) !void {
        try self.bindings.put(allocator, @bitCast(chord), action);
    }

    pub fn get(self: *const Table, chord: KeyChord) ?Action {
        return self.bindings.get(@bitCast(chord));
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.bindings.deinit(allocator);
    }
};

pub const KeyTables = struct {
    normal: Table = .{},
    insert: Table = .{},
    command: Table = .{},

    pub fn get(self: *const KeyTables, mode: Mode) *const Table {
        return switch (mode) {
            .normal => &self.normal,
            .insert => &self.insert,
            .command => &self.command,
        };
    }

    pub fn deinit(self: *KeyTables, allocator: std.mem.Allocator) void {
        self.normal.deinit(allocator);
        self.insert.deinit(allocator);
        self.command.deinit(allocator);
    }
};

/// Build the normal-mode dispatch table.
pub fn buildNormalTable(allocator: std.mem.Allocator) !Table {
    var t = Table{};

    // Arrow keys
    try t.put(allocator, keyChord(.arrow_left, 0), actions.collapseLeft);
    try t.put(allocator, keyChord(.arrow_right, 0), actions.collapseRight);
    try t.put(allocator, keyChord(.arrow_up, 0), actions.moveUp);
    try t.put(allocator, keyChord(.arrow_down, 0), actions.moveDown);

    // Escape / backspace
    try t.put(allocator, keyChord(.escape, 0), actions.normalEscape);
    try t.put(allocator, keyChord(.backspace, 0), actions.normalDeleteBack);
    try t.put(allocator, keyChord(.backspace, MOD_SHIFT), actions.normalDeleteForward);

    // h/l: collapse-or-move; H/L: extend selection
    try t.put(allocator, charChord('h', 0), actions.collapseLeft);
    try t.put(allocator, charChord('l', 0), actions.collapseRight);
    try t.put(allocator, charChord('H', 0), actions.extendLeft);
    try t.put(allocator, charChord('L', 0), actions.extendRight);

    // Word motion
    try t.put(allocator, charChord('w', 0), actions.wordNext);
    try t.put(allocator, charChord('W', 0), actions.wordNextExtend);
    try t.put(allocator, charChord('b', 0), actions.wordPrev);
    try t.put(allocator, charChord('B', 0), actions.wordPrevExtend);

    // Line start/end
    try t.put(allocator, charChord('[', 0), actions.lineStart);
    try t.put(allocator, charChord(']', 0), actions.lineEnd);
    try t.put(allocator, charChord('{', 0), actions.lineStartExtend);
    try t.put(allocator, charChord('}', 0), actions.lineEndExtend);

    // Line selection
    try t.put(allocator, charChord('x', 0), actions.selectLine);
    try t.put(allocator, charChord('X', 0), actions.selectLineBackward);

    // Mode transitions
    try t.put(allocator, charChord('i', 0), actions.enterInsert);
    try t.put(allocator, charChord('I', 0), actions.enterInsertLineStart);
    try t.put(allocator, charChord('\'', 0), actions.enterInsertLineEnd);
    try t.put(allocator, charChord('o', 0), actions.openLineBelow);
    try t.put(allocator, charChord('O', 0), actions.openLineAbove);

    // Edit
    try t.put(allocator, charChord('d', 0), actions.deleteOp);
    try t.put(allocator, charChord('D', 0), actions.deleteLines);
    try t.put(allocator, charChord('y', 0), actions.yank);
    try t.put(allocator, charChord('Y', 0), actions.paste);
    try t.put(allocator, charChord('c', 0), actions.cut);
    try t.put(allocator, charChord('t', 0), actions.transposeChars);
    try t.put(allocator, charChord('T', 0), actions.transposeWords);
    try t.put(allocator, charChord('&', 0), actions.duplicateAfter);
    try t.put(allocator, charChord('&', MOD_ALT), actions.duplicateBefore);

    // j/k: move down/up; alt+j/k: move line down/up.
    // JS lowercases alt+letter, so Alt+J and Alt+j both arrive as 'j'+MOD_ALT.
    try t.put(allocator, charChord('j', 0), actions.moveDown);
    try t.put(allocator, charChord('j', MOD_ALT), actions.moveLineDown);
    try t.put(allocator, charChord('k', 0), actions.moveUp);
    try t.put(allocator, charChord('k', MOD_ALT), actions.moveLineUp);

    // J/K: add cursor (alt+j/k already claimed by line-move above).
    try t.put(allocator, charChord('J', 0), actions.addCursorDown);
    try t.put(allocator, charChord('K', 0), actions.addCursorUp);

    // Undo / redo.  Alt+letter arrives lowercase from JS; Alt+Shift+U → 'u'+MOD_SHIFT+MOD_ALT.
    try t.put(allocator, charChord('u', 0), actions.undoOp);
    try t.put(allocator, charChord('u', MOD_ALT), actions.undoOlderOp);
    try t.put(allocator, charChord('U', 0), actions.redoOp);
    try t.put(allocator, charChord('u', MOD_SHIFT | MOD_ALT), actions.undoNewerOp);

    try t.put(allocator, charChord(':', 0), actions.dropToSingleCursor);
    try t.put(allocator, charChord(';', 0), actions.collapseSelections);

    // Search
    try t.put(allocator, charChord('/', 0), actions.searchForwardOp);
    try t.put(allocator, charChord('?', 0), actions.searchBackwardOp);
    try t.put(allocator, charChord('s', 0), actions.splitSelections);
    try t.put(allocator, charChord('S', 0), actions.splitSelectionsComplement);
    try t.put(allocator, charChord('v', 0), actions.filterKeep);
    try t.put(allocator, charChord('V', 0), actions.filterDrop);
    try t.put(allocator, charChord('n', 0), actions.nextMatch);
    try t.put(allocator, charChord('N', 0), actions.nextMatchAdd);
    try t.put(allocator, charChord('p', 0), actions.prevMatch);
    try t.put(allocator, charChord('P', 0), actions.prevMatchAdd);
    try t.put(allocator, charChord('*', 0), actions.selectAllMatches);

    // Settings
    try t.put(allocator, charChord(' ', 0), actions.openSettings);

    // Multi-key prefix setups (g, C, a, A, ", m)
    try t.put(allocator, charChord('g', 0), actions.pendingPrefixSetup);
    try t.put(allocator, charChord('C', 0), actions.pendingPrefixSetup);
    try t.put(allocator, charChord('a', 0), actions.pendingPrefixSetup);
    try t.put(allocator, charChord('A', 0), actions.pendingPrefixSetup);
    try t.put(allocator, charChord('"', 0), actions.pendingPrefixSetup);
    try t.put(allocator, charChord('m', 0), actions.pendingPrefixSetup);

    // Replace / sneak setups
    try t.put(allocator, charChord('r', 0), actions.replaceLeftSetup);
    try t.put(allocator, charChord('R', 0), actions.replaceRightSetup);
    try t.put(allocator, charChord('f', 0), actions.sneakForwardSetup);
    try t.put(allocator, charChord('F', 0), actions.sneakBackwardSetup);

    return t;
}

/// Build the insert-mode dispatch table.
pub fn buildInsertTable(allocator: std.mem.Allocator) !Table {
    var t = Table{};
    t.default_action = actions.selfInsert;

    try t.put(allocator, keyChord(.escape, 0), actions.insertEscape);
    try t.put(allocator, keyChord(.backspace, 0), actions.insertBackspace);
    try t.put(allocator, keyChord(.enter, 0), actions.insertEnter);
    try t.put(allocator, keyChord(.tab, 0), actions.insertTab);
    try t.put(allocator, keyChord(.arrow_left, 0), actions.moveLeft);
    try t.put(allocator, keyChord(.arrow_right, 0), actions.moveRight);
    try t.put(allocator, keyChord(.arrow_up, 0), actions.moveUp);
    try t.put(allocator, keyChord(.arrow_down, 0), actions.moveDown);
    try t.put(allocator, charChord('y', MOD_CTRL), actions.insertPaste);
    try t.put(allocator, charChord('w', MOD_CTRL), actions.insertWordDelete);

    return t;
}

/// Build the command-mode (palette) dispatch table.
pub fn buildCommandTable(allocator: std.mem.Allocator) !Table {
    var t = Table{};
    t.default_action = actions.paletteInsert;

    try t.put(allocator, keyChord(.escape, 0), actions.paletteEscape);
    try t.put(allocator, keyChord(.enter, 0), actions.paletteEnter);
    try t.put(allocator, keyChord(.backspace, 0), actions.paletteBackspace);
    try t.put(allocator, keyChord(.arrow_up, 0), actions.paletteUp);
    try t.put(allocator, keyChord(.arrow_down, 0), actions.paletteDown);
    try t.put(allocator, keyChord(.arrow_left, 0), actions.paletteLeft);
    try t.put(allocator, keyChord(.arrow_right, 0), actions.paletteRight);

    return t;
}
