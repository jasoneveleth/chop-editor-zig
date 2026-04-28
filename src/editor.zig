const std = @import("std");
const draw = @import("draw.zig");
const Buffer = @import("buffer.zig").Buffer;
const BufferId = @import("buffer.zig").BufferId;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const WindowId = window_mod.WindowId;
const PendingState = window_mod.PendingState;
const buffer_view_mod = @import("buffer_view.zig");
const BufferView = buffer_view_mod.BufferView;
const BufferViewId = buffer_view_mod.BufferViewId;
const CursorPool = buffer_view_mod.CursorPool;
const MAX_CURSORS = buffer_view_mod.MAX_CURSORS;
const cursor_mod = @import("cursor.zig");
const Cursor = cursor_mod.Cursor;
const Key = @import("key.zig").Key;
const MOD_CTRL = @import("key.zig").MOD_CTRL;
const MOD_SHIFT = @import("key.zig").MOD_SHIFT;
const MOD_ALT = @import("key.zig").MOD_ALT;
const palette_mod = @import("palette.zig");
const Palette = palette_mod.Palette;
const Match = palette_mod.Match;
const Regex = @import("regex").Regex;
const PaletteConfig = palette_mod.PaletteConfig;
const PickerItem = palette_mod.PickerItem;
const findNextMatchFrom = palette_mod.findNextMatchFrom;
const findPrevMatchFrom = palette_mod.findPrevMatchFrom;
const SETTINGS_ITEMS = palette_mod.SETTINGS_ITEMS;
const TAB_WIDTH_ITEMS = palette_mod.TAB_WIDTH_ITEMS;
const LANGUAGE_ITEMS = palette_mod.LANGUAGE_ITEMS;
const COLORSCHEME_ITEMS = palette_mod.COLORSCHEME_ITEMS;
const Op = @import("op.zig").Op;
const Colorscheme = @import("op.zig").Colorscheme;
const platform = @import("platform/web.zig");
const grapheme = @import("grapheme.zig");
const Highlighter = @import("highlighter.zig").Highlighter;
const FILLER_TEXT = @import("filler.zig").FILLER_TEXT;
const keybinds = @import("keybinds.zig");
const actions = @import("actions.zig");

// ── Cursor movement helpers ────────────────────────────────────────────────

/// Convert a click position to a buffer byte offset.
fn posFromPoint(win: *const Window, buf: *const Buffer, content: []const u8, click_x: f32, click_y: f32) usize {
    const line_height = win.font_size * 1.4;
    const gutter_width: f32 = 8;

    if (buf.softwrap and buf.wrap_rows.items.len > 0) {
        const row_idx: usize = @min(
            @as(usize, @intFromFloat(@floor(@max(0.0, (click_y + win.scroll_y) / line_height)))),
            buf.wrap_rows.items.len - 1,
        );
        const row = buf.wrap_rows.items[row_idx];
        return cursor_mod.closestPosToX(content, row.start, row.end, click_x - gutter_width, win.font_size);
    }

    const line_idx: usize = @intFromFloat(@floor(@max(0.0, (click_y + win.scroll_y) / line_height)));
    var current_line: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        const at_end = i == content.len;
        const at_nl = !at_end and content[i] == '\n';
        if (at_nl or at_end) {
            if (current_line == line_idx)
                return cursor_mod.closestPosToX(content, line_start, i, click_x - gutter_width, win.font_size);
            line_start = i + 1;
            current_line += 1;
        }
    }
    return content.len;
}

pub const Editor = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(Window),
    buffers: std.ArrayList(Buffer),
    buffer_views: std.ArrayList(BufferView),
    cursor_pool: CursorPool,
    /// Maps BufferId (bit-cast to u32) → list of BufferViewIds watching that buffer.
    buffer_view_map: std.AutoHashMap(u32, std.ArrayList(BufferViewId)),
    focused_window: WindowId,
    palette: Palette,
    last_input_ms: f64 = 0,
    colorscheme: Colorscheme = .onedark,
    drag_anchor: ?usize = null,
    highlighters: std.ArrayList(Highlighter),
    tab_width: u8 = 4,
    key_tables: keybinds.KeyTables = .{},

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, is_dark: bool) !Editor {
        var editor = Editor{
            .allocator = allocator,
            .windows = .{},
            .buffers = .{},
            .buffer_views = .{},
            .cursor_pool = .{},
            .buffer_view_map = std.AutoHashMap(u32, std.ArrayList(BufferViewId)).init(allocator),
            .focused_window = undefined,
            .palette = undefined,
            .colorscheme = if (is_dark) .onedark else .alabaster,
            .highlighters = .{},
        };

        // Main buffer + cursor set + window.
        const buf_id = try editor.createBuffer();
        editor.getBuffer(buf_id).?.insert(0, FILLER_TEXT) catch {};
        editor.highlighters.items[buf_id.index].rehighlight(FILLER_TEXT) catch {};
        const cs_id = try editor.createBufferView(buf_id);
        try editor.getBufferView(cs_id).?.insert(&editor.cursor_pool, Cursor.init(0));
        editor.focused_window = try editor.createWindow(buf_id, cs_id, width, height);

        editor.palette = Palette.init();
        editor.key_tables = .{
            .normal  = try keybinds.buildNormalTable(allocator),
            .insert  = try keybinds.buildInsertTable(allocator),
            .command = try keybinds.buildCommandTable(allocator),
        };

        return editor;
    }

    pub fn deinit(self: *Editor) void {
        self.key_tables.deinit(self.allocator);
        self.palette.deinit(self.allocator);
        var it = self.buffer_view_map.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.buffer_view_map.deinit();
        for (self.buffers.items) |*b| b.deinit();
        for (self.highlighters.items) |*h| h.deinit();
        self.highlighters.deinit();
        self.cursor_pool.deinit(self.allocator);
        self.windows.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
        self.buffer_views.deinit(self.allocator);
    }

    pub fn createBuffer(self: *Editor) !BufferId {
        const index: u24 = @intCast(self.buffers.items.len);
        const id = BufferId{ .index = index, .generation = 0 };
        try self.buffers.append(self.allocator, try Buffer.init(self.allocator));
        const h = try Highlighter.init(self.allocator, id);
        try self.highlighters.append(self.allocator, h);
        return id;
    }

    pub fn createBufferView(self: *Editor, buffer_id: BufferId) !BufferViewId {
        const index: u24 = @intCast(self.buffer_views.items.len);
        const cs_start = try self.cursor_pool.allocSlots(self.allocator, MAX_CURSORS);
        try self.buffer_views.append(self.allocator, BufferView.init(buffer_id, cs_start));
        const id = BufferViewId{ .index = index, .generation = 0 };
        const key: u32 = @bitCast(buffer_id);
        const gop = try self.buffer_view_map.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.append(self.allocator, id);
        return id;
    }

    pub fn createWindow(self: *Editor, buffer_id: BufferId, buffer_view_id: BufferViewId, width: u32, height: u32) !WindowId {
        const index: u24 = @intCast(self.windows.items.len);
        try self.windows.append(self.allocator, Window.init(buffer_id, buffer_view_id, width, height));
        return WindowId{ .index = index, .generation = 0 };
    }

    pub fn getWindow(self: *Editor, id: WindowId) ?*Window {
        if (id.index >= self.windows.items.len) return null;
        return &self.windows.items[id.index];
    }

    pub fn getBuffer(self: *Editor, id: BufferId) ?*Buffer {
        if (id.index >= self.buffers.items.len) return null;
        return &self.buffers.items[id.index];
    }

    pub fn getBufferView(self: *Editor, id: BufferViewId) ?*BufferView {
        if (id.index >= self.buffer_views.items.len) return null;
        return &self.buffer_views.items[id.index];
    }

    /// Infallible buffer accessor — valid whenever the window/buffer_id was created by this editor.
    pub fn bufOf(self: *Editor, id: BufferId) *Buffer {
        return &self.buffers.items[id.index];
    }

    // Fan-out functions moved to free functions doInsert/doDelete below.

    // ── Search ────────────────────────────────────────────────────────────────

    pub fn openPalette(self: *Editor, config: PaletteConfig) !void {
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getBufferView(win.buffer_view_id) orelse return;

        if (config.require_selection and !cs.hasSelection(&self.cursor_pool)) return;

        self.palette.active = config;
        self.palette.picker_items = config.picker_items;
        self.palette.picker_selected = 0;
        const snap_start = self.cursor_pool.snapshotRange(self.allocator, cs.start, cs.len) catch cs.start;
        self.palette.saved_cursors = .{ .buffer_id = cs.buffer_id, .start = snap_start, .len = cs.len };

        self.palette.input.clear();
        self.palette.matches.clearRetainingCapacity();
        win.mode = .command;

        if (config.prepopulate_selection) {
            const cs_items = cs.iter(&self.cursor_pool);
            if (cs.len == 1 and cs_items[0].isSelection()) {
                const main_buf = self.getBuffer(win.buffer_id) orelse return;
                const c = cs_items[0];
                const selected = main_buf.bytes()[c.start()..c.end()];
                self.palette.input.setText(selected);
                self.updateMatches() catch {};
            }
        }
    }

    fn executeSplit(self: *Editor, text: []const u8, complement: bool) void {
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getBufferView(win.buffer_view_id) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const content = buf.bytes();
        const pattern: []const u8 = if (text.len == 0) "\n" else text;
        const saved = self.palette.saved_cursors;
        cs.clear();

        var re = Regex.compile(self.allocator, pattern) catch null;
        defer if (re) |*r| r.deinit();

        if (!complement) {
            for (self.cursor_pool.slice(saved.start, saved.len)) |cursor| {
                if (!cursor.isSelection()) continue;
                const sel_start = cursor.start();
                const sel_end   = cursor.end();
                var i: usize = sel_start;
                if (re) |*r| {
                    while (i < sel_end) {
                        if (r.match(content[i..sel_end]) catch false and r.slots.items.len >= 2) {
                            if (r.slots.items[1]) |end_offset| {
                                cs.insert(&self.cursor_pool, .{ .anchor = i, .head = i + end_offset }) catch break;
                                if (end_offset == 0) { i += 1; } else { i += end_offset; }
                                continue;
                            }
                        }
                        i += 1;
                    }
                } else {
                    while (i + pattern.len <= sel_end) {
                        if (std.mem.eql(u8, content[i .. i + pattern.len], pattern)) {
                            cs.insert(&self.cursor_pool, .{ .anchor = i, .head = i + pattern.len }) catch break;
                            i += pattern.len;
                        } else {
                            i += 1;
                        }
                    }
                }
            }
        } else {
            for (self.cursor_pool.slice(saved.start, saved.len)) |cursor| {
                if (!cursor.isSelection()) continue;
                const sel_start = cursor.start();
                const sel_end   = cursor.end();
                var gap_start: usize = sel_start;
                var i: usize = sel_start;
                if (re) |*r| {
                    while (i < sel_end) {
                        if (r.match(content[i..sel_end]) catch false and r.slots.items.len >= 2) {
                            if (r.slots.items[1]) |end_offset| {
                                if (gap_start < i)
                                    cs.insert(&self.cursor_pool, .{ .anchor = gap_start, .head = i }) catch break;
                                if (end_offset == 0) { i += 1; } else { i += end_offset; }
                                gap_start = i;
                                continue;
                            }
                        }
                        i += 1;
                    }
                } else {
                    while (i + pattern.len <= sel_end) {
                        if (std.mem.eql(u8, content[i .. i + pattern.len], pattern)) {
                            if (gap_start < i)
                                cs.insert(&self.cursor_pool, .{ .anchor = gap_start, .head = i }) catch break;
                            i += pattern.len;
                            gap_start = i;
                        } else {
                            i += 1;
                        }
                    }
                }
                if (gap_start < sel_end)
                    cs.insert(&self.cursor_pool, .{ .anchor = gap_start, .head = sel_end }) catch {};
            }
        }

        if (cs.len == 0) cs.restoreFrom(&self.cursor_pool, saved.start, saved.len);
        self.palette.matches.clearRetainingCapacity();
    }

    fn executeFilter(self: *Editor, text: []const u8, keep: bool) void {
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getBufferView(win.buffer_view_id) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const content = buf.bytes();
        const saved = self.palette.saved_cursors;
        cs.clear();

        for (self.cursor_pool.slice(saved.start, saved.len)) |cursor| {
            if (!cursor.isSelection()) continue;
            const sel_start = cursor.start();
            const sel_end   = cursor.end();
            const sel_text  = content[sel_start..sel_end];
            const found = blk: {
                if (text.len == 0) break :blk false;
                var re = Regex.compile(self.allocator, text) catch break :blk std.mem.indexOf(u8, sel_text, text) != null;
                defer re.deinit();
                var j: usize = 0;
                while (j < sel_text.len) : (j += 1) {
                    if (re.match(sel_text[j..]) catch false) break :blk true;
                }
                break :blk false;
            };
            const include = if (keep) found else !found;
            if (include) cs.insert(&self.cursor_pool, cursor) catch break;
        }

        if (cs.len == 0) cs.restoreFrom(&self.cursor_pool, saved.start, saved.len);
        self.palette.matches.clearRetainingCapacity();
    }

    fn executeSearch(self: *Editor, direction: enum { forward, backward }) void {
        const win = self.getWindow(self.focused_window) orelse return;
        const cs = self.getBufferView(win.buffer_view_id) orelse return;
        const saved = self.palette.saved_cursors;

        if (self.palette.matches.items.len > 0) {
            const saved_head = if (saved.len > 0)
                self.cursor_pool.slice(saved.start, saved.len)[0].head
            else
                0;
            const m = switch (direction) {
                .forward  => findNextMatchFrom(self.palette.matches.items, saved_head) orelse self.palette.matches.items[0],
                .backward => findPrevMatchFrom(self.palette.matches.items, saved_head) orelse self.palette.matches.items[self.palette.matches.items.len - 1],
            };
            cs.clear();
            cs.insert(&self.cursor_pool, .{ .head = m.end, .anchor = m.start }) catch {};
        } else {
            cs.restoreFrom(&self.cursor_pool, saved.start, saved.len);
            self.palette.matches.clearRetainingCapacity();
        }
    }

    pub fn closePalette(self: *Editor, confirm: bool) void {
        const win = self.getWindow(self.focused_window) orelse return;
        win.mode = .normal;
        const cs = self.getBufferView(win.buffer_view_id) orelse return;

        const config = self.palette.active orelse return;

        if (confirm) {
            const text = self.palette.input.bytes();
            switch (config.op_kind) {
                .search_forward              => self.executeSearch(.forward),
                .search_backward             => self.executeSearch(.backward),
                .split_selections            => self.executeSplit(text, false),
                .split_selections_complement => self.executeSplit(text, true),
                .filter_keep                 => self.executeFilter(text, true),
                .filter_drop                 => self.executeFilter(text, false),
                .settings_palette,
                .tab_width_palette,
                .language_palette,
                .colorscheme_palette => {
                    // Reproduce the same ranked filter as drawPalette to find the selected item.
                    var cl_filtered_buf: [32]usize = undefined;
                    var cl_scores_buf: [32]palette_mod.MatchScore = undefined;
                    var cl_filtered_len: usize = 0;
                    for (self.palette.picker_items, 0..) |item, i| {
                        const score = palette_mod.scoreMatch(text, item.label);
                        if (score.tier != 255) {
                            cl_filtered_buf[cl_filtered_len] = i;
                            cl_scores_buf[cl_filtered_len] = score;
                            cl_filtered_len += 1;
                            if (cl_filtered_len >= cl_filtered_buf.len) break;
                        }
                    }
                    if (text.len > 0)
                        palette_mod.sortResults(cl_filtered_buf[0..cl_filtered_len], cl_scores_buf[0..cl_filtered_len]);
                    if (self.palette.picker_selected < cl_filtered_len) {
                        const item = self.palette.picker_items[cl_filtered_buf[self.palette.picker_selected]];
                        self.executeOp(item.op_on_confirm);
                    }
                },
            }
        } else {
            cs.restoreFrom(&self.cursor_pool, self.palette.saved_cursors.start, self.palette.saved_cursors.len);
            self.palette.matches.clearRetainingCapacity();
        }

        self.palette.active = null;
    }

    pub fn requireFreshMatches(self: *Editor) void {
        if (self.palette.matches_stale) {
            self.updateMatches() catch {};
        }
    }

    pub fn updateMatches(self: *Editor) !void {
        self.palette.matches_stale = false;
        self.palette.matches.clearRetainingCapacity();
        const win = self.getWindow(self.focused_window) orelse return;
        const main_buf = self.getBuffer(win.buffer_id) orelse return;

        const pattern = self.palette.input.bytes();
        if (pattern.len == 0) return;
        const content = main_buf.bytes();

        var re = Regex.compile(self.allocator, pattern) catch {
            return self.updateMatchesLiteral(pattern, content);
        };
        defer re.deinit();
        try self.collectRegexMatches(&re, content);
    }

    fn updateMatchesLiteral(self: *Editor, pattern: []const u8, content: []const u8) void {
        var i: usize = 0;
        while (i + pattern.len <= content.len) {
            if (std.mem.eql(u8, content[i .. i + pattern.len], pattern)) {
                self.palette.matches.append(self.allocator, .{ .start = i, .end = i + pattern.len }) catch return;
                i += pattern.len;
            } else {
                i += 1;
            }
        }
    }

    // Use anchored re.match() at each position rather than re.captures() which uses
    // find_start (compiled as `.*?` with AnyCharNotNL) and stops scanning at newlines.
    fn collectRegexMatches(self: *Editor, re: *Regex, content: []const u8) !void {
        var i: usize = 0;
        while (i < content.len) {
            if (try re.match(content[i..]) and re.slots.items.len >= 2) {
                if (re.slots.items[1]) |end_offset| {
                    try self.palette.matches.append(self.allocator, .{ .start = i, .end = i + end_offset });
                    if (end_offset == 0) { i += 1; } else { i += end_offset; }
                    continue;
                }
            }
            i += 1;
        }
    }

    fn executeOp(self: *Editor, op: Op) void {
        switch (op) {
            .tab_width_palette => {
                self.openPalette(.{
                    .prompt_symbol = "tab:",
                    .op_kind = .tab_width_palette,
                    .prepopulate_selection = false,
                    .picker_items = &TAB_WIDTH_ITEMS,
                }) catch {};
            },
            .language_palette => {
                self.openPalette(.{
                    .prompt_symbol = "lang:",
                    .op_kind = .language_palette,
                    .prepopulate_selection = false,
                    .picker_items = &LANGUAGE_ITEMS,
                }) catch {};
            },
            .colorscheme_palette => {
                self.openPalette(.{
                    .prompt_symbol = "theme:",
                    .op_kind = .colorscheme_palette,
                    .prepopulate_selection = false,
                    .picker_items = &COLORSCHEME_ITEMS,
                }) catch {};
            },
            .toggle_softwrap => {
                const win = self.getWindow(self.focused_window) orelse return;
                const buf = self.getBuffer(win.buffer_id) orelse return;
                buf.softwrap = !buf.softwrap;
            },
            .set_tab_width => |width| {
                self.tab_width = width;
            },
            .set_colorscheme => |scheme| {
                self.colorscheme = scheme;
            },
            .set_language => |lang| {
                const win = self.getWindow(self.focused_window) orelse return;
                const h = &self.highlighters.items[win.buffer_id.index];
                h.setLanguage(lang);
                if (lang == .zig) {
                    const buf = self.getBuffer(win.buffer_id) orelse return;
                    h.rehighlight(buf.bytes()) catch {};
                }
            },
        }
    }

    // ── Rendering ─────────────────────────────────────────────────────────────

    pub fn buildDrawList(self: *Editor, dl: *draw.DrawList, time_ms: f64) !void {
        const cursor_visible = @mod(time_ms - self.last_input_ms, 1000) < 667;

        const win = self.getWindow(self.focused_window) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const cs = self.getBufferView(win.buffer_view_id) orelse return;

        const available_w = win.width - 8; // gutter_width
        try buf.buildWrapRows(available_w, win.font_size);

        const highlights: []const Match = if (win.mode == .command) self.palette.matches.items else &.{};
        const spans = self.highlighters.items[win.buffer_id.index].spans.items;
        try win.buildDrawList(dl, buf, cs, &self.cursor_pool, highlights, spans, cursor_visible, self.colorscheme);

        if (win.mode == .command) try self.drawPalette(dl, win, self.colorscheme);
    }

    fn drawPalette(self: *Editor, dl: *draw.DrawList, win: *const Window, scheme: Colorscheme) !void {
        const dark_mode = scheme == .onedark;
        if (self.palette.active == null) return;
        const font_size: f32 = 14;
        const line_height = font_size * 1.4;
        const input_row_h: f32 = line_height * 1.5;
        const item_row_h: f32  = line_height * 1.4;

        const pal_w: f32 = @min(600, @max(win.width - 80, 800));
        const pal_x: f32 = (win.width - pal_w) / 2;
        const pal_y: f32 = 24;
        const text_x = pal_x + 14;

        const pal_bg   = if (dark_mode) draw.Color.rgb(45, 45, 45)   else draw.Color.rgb(220, 220, 220);
        const pal_dim  = if (dark_mode) draw.Color.rgb(100, 100, 100) else draw.Color.rgb(130, 130, 130);
        const pal_text = if (dark_mode) draw.Color.rgb(220, 220, 220) else draw.Color.rgb(27, 27, 27);
        const sel_bg   = if (dark_mode) draw.Color.rgb(55, 75, 115)   else draw.Color.rgb(180, 200, 240);

        // Pattern text (drives both display and picker filtering).
        const pattern = self.palette.input.bytes();

        // Compute filtered+ranked picker items (indices into picker_items, max 32).
        var filtered_buf: [32]usize = undefined;
        var scores_buf: [32]palette_mod.MatchScore = undefined;
        var filtered_len: usize = 0;
        for (self.palette.picker_items, 0..) |item, i| {
            const score = palette_mod.scoreMatch(pattern, item.label);
            if (score.tier != 255) {
                filtered_buf[filtered_len] = i;
                scores_buf[filtered_len] = score;
                filtered_len += 1;
                if (filtered_len >= filtered_buf.len) break;
            }
        }
        if (pattern.len > 0)
            palette_mod.sortResults(filtered_buf[0..filtered_len], scores_buf[0..filtered_len]);
        const filtered = filtered_buf[0..filtered_len];

        // Total height: input row + item rows.
        const pal_h = input_row_h + item_row_h * @as(f32, @floatFromInt(filtered_len));
        try dl.fillRect(.{ .x = pal_x, .y = pal_y, .w = pal_w, .h = pal_h }, pal_bg);

        // ── Text input row ──────────────────────────────────────────────────
        const baseline = pal_y + input_row_h / 2 + font_size / 3;
        const prompt = self.palette.promptSymbol();
        const prompt_w = platform.measureText(prompt, font_size);
        try dl.drawText(text_x, baseline, prompt, pal_dim, font_size);

        const pat_x = text_x + prompt_w + 6;
        try dl.drawText(pat_x, baseline, pattern, pal_text, font_size);

        // Match count hint (text palettes).
        if (self.palette.matches.items.len > 0) {
            const count_str = std.fmt.bufPrint(&self.palette.count_buf, "{d} matches", .{self.palette.matches.items.len}) catch "";
            const count_x = pal_x + pal_w - platform.measureText(count_str, font_size) - 14;
            try dl.drawText(count_x, baseline, count_str, pal_dim, font_size);
        }

        // Text cursor.
        {
            const cur_head = self.palette.input.cursor;
            const cx = pat_x + platform.measureText(pattern[0..cur_head], font_size);
            const cur_y = pal_y + (input_row_h - line_height) / 2;
            try dl.fillRect(.{ .x = cx - 1, .y = cur_y, .w = 2, .h = line_height }, draw.Color.rgb(0, 196, 255));
        }

        // ── Filtered picker items ───────────────────────────────────────────
        for (filtered, 0..) |item_idx, fi| {
            const item = self.palette.picker_items[item_idx];
            const item_y = pal_y + input_row_h + @as(f32, @floatFromInt(fi)) * item_row_h;
            if (fi == self.palette.picker_selected) {
                try dl.fillRect(.{ .x = pal_x + 2, .y = item_y, .w = pal_w - 4, .h = item_row_h }, sel_bg);
            }
            const item_baseline = item_y + item_row_h / 2 + font_size / 3;
            try dl.drawText(text_x, item_baseline, item.label, pal_text, font_size);
        }
    }

    // ── Input ─────────────────────────────────────────────────────────────────

    /// Insert text for each cursor independently.
    /// Uses strict `> pos` adjustment so overlapping cursors separate rather than
    /// all being bumped to the same post-insertion position.
    pub fn insertAtCursors(self: *Editor, win: *Window, cs: *BufferView, text: []const u8) void {
        const buf_obj = self.bufOf(win.buffer_id);
        var idx = cs.len;
        while (idx > 0) {
            idx -= 1;
            const items = cs.iter(&self.cursor_pool);
            const pos = items[idx].head;
            buf_obj.insert(pos, text) catch continue;
            items[idx].head = pos + (idx + 1) * text.len;
            items[idx].anchor = items[idx].head;
        }
        self.palette.matches_stale = true;
        self.highlighters.items[win.buffer_id.index].rehighlight(buf_obj.bytes()) catch {};
    }

    const Dir = enum { left, right, up, down };

    pub fn deleteSelections(self: *Editor, win: *Window, cs: *BufferView) void {
        var it = cs.reverseIter(&self.cursor_pool);
        while (it.next()) |cursor| {
            if (cursor.isSelection())
                doDelete(self,win.buffer_id, cursor.start(), cursor.end() - cursor.start());
        }
    }

    pub fn extendSelection(self: *Editor, win: *Window, cs: *BufferView, dir: Dir) void {
        const buf = self.bufOf(win.buffer_id);
        const content = buf.bytes();
        win.preferred_col = null;
        for (cs.iter(&self.cursor_pool)) |*c| {
            c.head = if (dir == .left) cursor_mod.cursorLeft(content, c.head) else cursor_mod.cursorRight(content, c.head);
        }
    }

    pub fn yank(self: *Editor, win: *Window, cs: *BufferView) void {
        if (cs.len == 0) return;
        const buf = self.bufOf(win.buffer_id);
        const content = buf.bytes();
        const c = cs.iter(&self.cursor_pool)[0];
        if (c.isSelection()) {
            platform.writeClipboard(content[c.start()..c.end()]);
        } else {
            const ls = grapheme.lineStart(content, c.head);
            const le = grapheme.findChars(content, c.head, "\n");
            const line_end = if (le < content.len) le + 1 else content.len;
            platform.writeClipboard(content[ls..line_end]);
        }
    }

    pub fn delete(self: *Editor, win: *Window, cs: *BufferView) void {
        if (cs.len == 0) return;
        const buf = self.bufOf(win.buffer_id);
        const content = buf.bytes();
        const c = cs.iter(&self.cursor_pool)[0];
        if (c.isSelection()) {
            self.deleteSelections(win, cs);
            cs.clearSelections(&self.cursor_pool);
        } else {
            const ls = grapheme.lineStart(content, c.head);
            const le = grapheme.findChars(content, c.head, "\n");
            const line_end = if (le < content.len) le + 1 else content.len;
            doDelete(self,win.buffer_id, ls, line_end - ls);
        }
    }

    pub fn cut(self: *Editor, win: *Window, cs: *BufferView) void {
        if (cs.len == 0) return;
        const buf = self.bufOf(win.buffer_id);
        const content = buf.bytes();
        const c = cs.iter(&self.cursor_pool)[0];
        if (c.isSelection()) {
            platform.writeClipboard(content[c.start()..c.end()]);
            self.deleteSelections(win, cs);
            cs.clearSelections(&self.cursor_pool);
        } else {
            const ls = grapheme.lineStart(content, c.head);
            const le = grapheme.findChars(content, c.head, "\n");
            const line_end = if (le < content.len) le + 1 else content.len;
            platform.writeClipboard(content[ls..line_end]);
            doDelete(self,win.buffer_id, ls, line_end - ls);
        }
    }

    pub fn paste(self: *Editor, win: *Window, cs: *BufferView) void {
        cs.clearSelections(&self.cursor_pool);
        const clip = platform.readClipboard();
        if (clip.len > 0) self.insertAtCursors(win, cs, clip);
    }

    pub fn move(self: *Editor, win: *Window, cs: *BufferView, dir: Dir) void {
        const buf = self.bufOf(win.buffer_id);
        const content = buf.bytes();
        for (cs.iter(&self.cursor_pool)) |*c| {
            switch (dir) {
                .left, .right => {
                    c.head = if (dir == .left) cursor_mod.cursorLeft(content, c.head) else cursor_mod.cursorRight(content, c.head);
                    win.preferred_col = null;
                },
                .up, .down => {
                    const ls = grapheme.lineStart(content, c.head);
                    const col_px = win.preferred_col orelse platform.measureText(content[ls..c.head], win.font_size);
                    win.preferred_col = col_px;
                    const rows = buf.wrap_rows.items;
                    c.head = if (buf.softwrap)
                        (if (dir == .up) window_mod.cursorUpWrapped(content, c.head, col_px, win.font_size, rows)
                                        else window_mod.cursorDownWrapped(content, c.head, col_px, win.font_size, rows))
                    else
                        (if (dir == .up) cursor_mod.cursorUp(content, c.head, col_px, win.font_size)
                                        else cursor_mod.cursorDown(content, c.head, col_px, win.font_size));
                },
            }
            c.anchor = c.head;
        }
    }

    pub fn execSneak(self: *Editor, win: *Window, cs: *BufferView, c1: u8, c2: u8, forward: bool) void {
        if (c1 == 0) return;
        const buf = self.bufOf(win.buffer_id);
        const content = buf.bytes();
        for (cs.iter(&self.cursor_pool)) |*c| {
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

    pub fn applyUndo(self: *Editor, win: *Window, cs: *BufferView) void {
        const buf = self.bufOf(win.buffer_id);
        buf.undo(cs, &self.cursor_pool);
        win.preferred_col = null;
        self.palette.matches_stale = true;
        self.highlighters.items[win.buffer_id.index].rehighlight(buf.bytes()) catch {};
    }

    pub fn applyRedo(self: *Editor, win: *Window, cs: *BufferView) void {
        const buf = self.bufOf(win.buffer_id);
        buf.redo(cs, &self.cursor_pool);
        win.preferred_col = null;
        self.palette.matches_stale = true;
        self.highlighters.items[win.buffer_id.index].rehighlight(buf.bytes()) catch {};
    }

    pub fn applyUndoOlder(self: *Editor, win: *Window, cs: *BufferView) void {
        const buf = self.bufOf(win.buffer_id);
        buf.undoOlder(cs, &self.cursor_pool);
        win.preferred_col = null;
        self.palette.matches_stale = true;
        self.highlighters.items[win.buffer_id.index].rehighlight(buf.bytes()) catch {};
    }

    pub fn applyUndoNewer(self: *Editor, win: *Window, cs: *BufferView) void {
        const buf = self.bufOf(win.buffer_id);
        buf.undoNewer(cs, &self.cursor_pool);
        win.preferred_col = null;
        self.palette.matches_stale = true;
        self.highlighters.items[win.buffer_id.index].rehighlight(buf.bytes()) catch {};
    }

    pub fn onKeyDown(self: *Editor, time_ms: f64, key: Key, mods: u32) void {
        self.last_input_ms = time_ms;
        const win = self.getWindow(self.focused_window) orelse return;
        const chord = keybinds.keyChord(key, mods);

        const was_normal = win.mode == .normal;
        if (was_normal) {
            const cs = self.getBufferView(win.buffer_view_id) orelse return;
            self.bufOf(win.buffer_id).history.begin(self.allocator, cs, &self.cursor_pool);
        }
        defer if (was_normal and win.mode != .insert) self.bufOf(win.buffer_id).history.commit(self.allocator);

        if (win.pending_key_handler) |handler| {
            win.pending_key_handler = null;
            win.preferred_col = null;
            handler(self, chord);
        } else {
            const table = self.key_tables.get(win.mode);
            if (table.get(chord)) |action| {
                action(self, chord);
            } else if (table.default_action) |default| {
                default(self, chord);
            }
        }

    }

    pub fn onKeyUp(self: *Editor, key: Key, mods: u32) void {
        _ = self;
        _ = key;
        _ = mods;
    }

    pub fn onMouse(self: *Editor, x: f32, y: f32, button: u8, kind: u8, mods: u32) void {
        const win = self.getWindow(self.focused_window) orelse return;
        const buf = self.getBuffer(win.buffer_id) orelse return;
        const cs = self.getBufferView(win.buffer_view_id) orelse return;

        // When palette is open, intercept all mouse events.
        if (win.mode == .command and self.palette.active != null) {
            if (kind == 1 and button == 0) {
                const font_size: f32 = 14;
                const line_height = font_size * 1.4;
                const input_row_h: f32 = line_height * 1.5;
                const item_row_h: f32  = line_height * 1.4;
                const pal_w: f32 = @min(600, @max(win.width - 80, 800));
                const pal_x: f32 = (win.width - pal_w) / 2;
                const pal_y: f32 = 24;

                if (x < pal_x or x > pal_x + pal_w or y < pal_y) {
                    // Click outside palette: close/cancel.
                    self.closePalette(false);
                } else if (y < pal_y + input_row_h) {
                    // Click on input row: place palette cursor at clicked position.
                    const pattern = self.palette.input.bytes();
                    const prompt = self.palette.promptSymbol();
                    const text_x = pal_x + 14;
                    const pat_x = text_x + platform.measureText(prompt, font_size) + 6;
                    const pos = cursor_mod.closestPosToX(pattern, 0, pattern.len, x - pat_x, font_size);
                    self.palette.input.cursor = @intCast(pos);
                } else {
                    // Click on an item row: select and confirm that item.
                    const fi: usize = @intFromFloat(@floor((y - pal_y - input_row_h) / item_row_h));
                    self.palette.picker_selected = fi;
                    self.closePalette(true);
                }
            }
            return;
        }

        switch (kind) {
            1 => { // mousedown
                if (button != 0) return;
                const pos = posFromPoint(win, buf, buf.bytes(), x, y);
                win.preferred_col = null;
                const alt = (mods & @import("key.zig").MOD_ALT) != 0;
                if (!alt) cs.clear();
                cs.insert(&self.cursor_pool, Cursor.init(pos)) catch {};
                if (!alt) self.drag_anchor = pos;
            },
            0 => { // mousemove
                const anchor = self.drag_anchor orelse return;
                const pos = posFromPoint(win, buf, buf.bytes(), x, y);
                cs.clear();
                cs.insert(&self.cursor_pool, .{
                    .head = pos,
                    .anchor = anchor,
                }) catch {};
            },
            2 => { // mouseup
                self.drag_anchor = null;
            },
            else => {},
        }
    }

    pub fn onScroll(self: *Editor, time_ms: f64, dx: f32, dy: f32) void {
        self.last_input_ms = time_ms;
        if (self.getWindow(self.focused_window)) |win| win.onScroll(dx, dy);
    }

    pub fn onResize(self: *Editor, width: u32, height: u32) void {
        if (self.getWindow(self.focused_window)) |win| win.onResize(width, height);
    }
};

// ── Fan-out free functions ────────────────────────────────────────────────────

/// Insert text into a buffer, adjust all watching views, and rehighlight.
/// Undo recording is handled by Buffer.insert (gated by history.recording).
pub fn doInsert(ed: *Editor, buffer_id: BufferId, pos: usize, text: []const u8) !void {
    const buf = ed.getBuffer(buffer_id) orelse return;
    try buf.insert(pos, text);
    const key: u32 = @bitCast(buffer_id);
    if (ed.buffer_view_map.get(key)) |ids| {
        for (ids.items) |bv_id| {
            if (ed.getBufferView(bv_id)) |bv| bv.adjustForInsert(&ed.cursor_pool, pos, text.len);
        }
    }
    ed.palette.matches_stale = true;
    ed.highlighters.items[buffer_id.index].rehighlight(buf.bytes()) catch {};
}

/// Delete from a buffer, adjust all watching views, and rehighlight.
/// Undo recording is handled by Buffer.delete (gated by history.recording).
pub fn doDelete(ed: *Editor, buffer_id: BufferId, pos: usize, len: usize) void {
    const buf = ed.getBuffer(buffer_id) orelse return;
    buf.delete(pos, len) catch {};
    const key: u32 = @bitCast(buffer_id);
    if (ed.buffer_view_map.get(key)) |ids| {
        for (ids.items) |bv_id| {
            if (ed.getBufferView(bv_id)) |bv| bv.adjustForDelete(&ed.cursor_pool, pos, len);
        }
    }
    ed.palette.matches_stale = true;
    const buf_after = ed.getBuffer(buffer_id) orelse return;
    ed.highlighters.items[buffer_id.index].rehighlight(buf_after.bytes()) catch {};
}
