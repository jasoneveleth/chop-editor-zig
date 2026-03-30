// Tree-sitter integration.
//
// Vendor setup (run once):
//   git clone --depth 1 https://github.com/tree-sitter/tree-sitter      vendor/tree-sitter
//   git clone --depth 1 https://github.com/maxxnino/tree-sitter-zig     vendor/tree-sitter-zig

const std = @import("std");
const BufferId = @import("buffer.zig").BufferId;
const highlight = @import("highlight.zig");
pub const Language = @import("op.zig").Language;

// ── Tree-sitter C API ─────────────────────────────────────────────────────────

const TSParser   = opaque {};
const TSTree     = opaque {};
const TSLanguage = opaque {};

const TSPoint = extern struct {
    row:    u32,
    column: u32,
};

// Value-type node handle — passed and returned by value from every ts_node_* fn.
pub const TSNode = extern struct {
    context: [4]u32,
    id:      ?*const anyopaque,
    tree:    ?*const anyopaque,
};

extern fn ts_parser_new() ?*TSParser;
extern fn ts_parser_delete(parser: *TSParser) void;
extern fn ts_parser_set_language(parser: *TSParser, language: *const TSLanguage) bool;
extern fn ts_parser_parse_string(
    parser:   *TSParser,
    old_tree: ?*const TSTree,
    str:      [*]const u8,
    len:      u32,
) ?*TSTree;

extern fn ts_tree_delete(tree: *TSTree) void;
extern fn ts_tree_root_node(tree: *const TSTree) TSNode;

extern fn ts_node_type(node: TSNode) [*:0]const u8;
extern fn ts_node_start_byte(node: TSNode) u32;
extern fn ts_node_end_byte(node: TSNode) u32;
extern fn ts_node_is_null(node: TSNode) bool;
extern fn ts_node_child_count(node: TSNode) u32;
extern fn ts_node_child(node: TSNode, index: u32) TSNode;
extern fn ts_node_named_child_count(node: TSNode) u32;
extern fn ts_node_named_child(node: TSNode, index: u32) TSNode;
extern fn ts_node_parent(node: TSNode) TSNode;

// Provided by vendor/tree-sitter-zig/src/parser.c
extern fn tree_sitter_zig() *const TSLanguage;

// ── Tag mapping ───────────────────────────────────────────────────────────────

// Maps tree-sitter-zig node type strings to highlight tags.
// Keywords appear as anonymous nodes whose .type IS the keyword text.
const TAG_MAP = std.StaticStringMap(highlight.Tag).initComptime(.{
    // Named node types (names from tree-sitter-zig's generated parser)
    .{ "line_comment",          .comment },
    .{ "container_doc_comment", .comment },
    .{ "doc_comment",           .comment },
    .{ "STRINGLITERALSINGLE",   .string  },
    .{ "LINESTRING",            .string  },
    .{ "CHAR_LITERAL",          .string  },
    .{ "INTEGER",               .number  },
    .{ "FLOAT",                 .number  },
    .{ "BUILTINIDENTIFIER",     .builtin },
    .{ "IDENTIFIER",            .identifier },

    // Punctuation (anonymous nodes — type == literal character)
    .{ "{", .punctuation }, .{ "}", .punctuation },
    .{ "(", .punctuation }, .{ ")", .punctuation },
    .{ "[", .punctuation }, .{ "]", .punctuation },
    .{ ";", .punctuation }, .{ ",", .punctuation },
    .{ ".", .punctuation },

    // Keywords (anonymous nodes — type == keyword text)
    .{ "fn",           .keyword }, .{ "pub",         .keyword },
    .{ "const",        .keyword }, .{ "var",         .keyword },
    .{ "if",           .keyword }, .{ "else",        .keyword },
    .{ "while",        .keyword }, .{ "for",         .keyword },
    .{ "return",       .keyword }, .{ "break",       .keyword },
    .{ "continue",     .keyword }, .{ "switch",      .keyword },
    .{ "struct",       .keyword }, .{ "enum",        .keyword },
    .{ "union",        .keyword }, .{ "error",       .keyword },
    .{ "try",          .keyword }, .{ "catch",       .keyword },
    .{ "defer",        .keyword }, .{ "errdefer",    .keyword },
    .{ "unreachable",  .keyword }, .{ "comptime",    .keyword },
    .{ "inline",       .keyword }, .{ "extern",      .keyword },
    .{ "packed",       .keyword }, .{ "export",      .keyword },
    .{ "test",         .keyword }, .{ "usingnamespace", .keyword },
    .{ "threadlocal",  .keyword }, .{ "allowzero",   .keyword },
    .{ "noalias",      .keyword }, .{ "volatile",    .keyword },
    .{ "and",          .keyword }, .{ "or",          .keyword },
    .{ "orelse",       .keyword }, .{ "null",        .keyword },
    .{ "undefined",    .keyword }, .{ "true",        .keyword },
    .{ "false",        .keyword }, .{ "anytype",     .keyword },
    .{ "noreturn",     .keyword }, .{ "anyopaque",   .keyword },
    .{ "void",         .keyword }, .{ "bool",        .keyword },
    .{ "type",         .keyword }, .{ "async",       .keyword },
    .{ "await",        .keyword }, .{ "suspend",     .keyword },
    .{ "resume",       .keyword }, .{ "nosuspend",   .keyword },
});

fn tagForTypeInContext(typ: []const u8, parent_type: []const u8) highlight.Tag {
    if (std.mem.eql(u8, typ, "IDENTIFIER")) {
        if (std.mem.eql(u8, parent_type, "VarDecl") or
            std.mem.eql(u8, parent_type, "ParamDecl"))
            return .identifier_decl;
        return .identifier;
    }
    return TAG_MAP.get(typ) orelse .default;
}

// ── Tree walker ───────────────────────────────────────────────────────────────

// Iterative DFS using an explicit stack to avoid call-stack overflow on deep trees.
// Pushes children in reverse order so the leftmost child is processed first,
// preserving left-to-right source order in the output spans.
const StackEntry = struct { node: TSNode, parent_type: []const u8 };

fn walkTree(root: TSNode, allocator: std.mem.Allocator, out: *std.ArrayList(highlight.Span)) !void {
    var stack: std.ArrayList(StackEntry) = .{};
    defer stack.deinit(allocator);

    try stack.append(allocator, .{ .node = root, .parent_type = "" });

    while (stack.items.len > 0) {
        const entry = stack.pop() orelse break;
        const node = entry.node;
        if (ts_node_is_null(node)) continue;

        const typ = std.mem.span(ts_node_type(node));
        const tag = tagForTypeInContext(typ, entry.parent_type);

        if (tag != .default) {
            try out.append(allocator, .{
                .start = ts_node_start_byte(node),
                .end   = ts_node_end_byte(node),
                .tag   = tag,
            });
            continue;
        }

        // Push children in reverse order, passing this node's type as their parent.
        const count = ts_node_child_count(node);
        var i: u32 = count;
        while (i > 0) {
            i -= 1;
            try stack.append(allocator, .{ .node = ts_node_child(node, i), .parent_type = typ });
        }
    }
}

// ── Highlighter ───────────────────────────────────────────────────────────────

pub const Highlighter = struct {
    buffer_id: BufferId,
    allocator: std.mem.Allocator,
    parser:    *TSParser,
    tree:      ?*TSTree,
    spans:     std.ArrayList(highlight.Span),
    language:  Language = .zig,

    pub fn init(allocator: std.mem.Allocator, buffer_id: BufferId) !Highlighter {
        const parser = ts_parser_new() orelse return error.TSParserAllocFailed;
        _ = ts_parser_set_language(parser, tree_sitter_zig());
        return .{
            .buffer_id = buffer_id,
            .allocator = allocator,
            .parser    = parser,
            .tree      = null,
            .spans     = .{},
        };
    }

    pub fn deinit(self: *Highlighter) void {
        if (self.tree) |t| ts_tree_delete(t);
        ts_parser_delete(self.parser);
        self.spans.deinit(self.allocator);
    }

    pub fn setLanguage(self: *Highlighter, lang: Language) void {
        self.language = lang;
        if (lang == .none) {
            if (self.tree) |t| {
                ts_tree_delete(t);
                self.tree = null;
            }
            self.spans.clearRetainingCapacity();
        }
    }

    /// Re-parse `source` and rebuild the span list.
    pub fn rehighlight(self: *Highlighter, source: []const u8) !void {
        if (self.language == .none) return;
        if (self.tree) |t| ts_tree_delete(t);
        self.tree = ts_parser_parse_string(
            self.parser,
            null,
            source.ptr,
            @intCast(source.len),
        );
        self.spans.clearRetainingCapacity();
        const tree = self.tree orelse return;
        const root = ts_tree_root_node(tree);
        try walkTree(root, self.allocator, &self.spans);
    }

    /// Walk down to the deepest node (named or anonymous) containing `byte_offset`,
    /// then walk up to root, writing "leaf -> parent -> ... -> root" into `buf`.
    /// Returns the portion of `buf` that was written.
    pub fn nodePathAtByte(self: *const Highlighter, byte_offset: u32, buf: []u8) []u8 {
        const tree = self.tree orelse return buf[0..0];

        // Walk down using all children (not just named) to reach the true leaf.
        var node = ts_tree_root_node(tree);
        outer: while (true) {
            const count = ts_node_child_count(node);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const child = ts_node_child(node, i);
                if (ts_node_start_byte(child) <= byte_offset and
                    byte_offset < ts_node_end_byte(child))
                {
                    node = child;
                    continue :outer;
                }
            }
            break;
        }

        // Walk up from leaf to root, appending each type separated by " -> ".
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        var cur = node;
        var first = true;
        while (true) {
            if (!first) w.writeAll(" -> ") catch break;
            first = false;
            w.writeAll(std.mem.span(ts_node_type(cur))) catch break;
            const parent = ts_node_parent(cur);
            if (ts_node_is_null(parent)) break;
            cur = parent;
        }
        return fbs.getWritten();
    }

    /// Return the ts_node_type string for the deepest named node at `byte_offset`,
    /// or null if there is no tree yet.
    pub fn nodeTypeAtByte(self: *const Highlighter, byte_offset: u32) ?[]const u8 {
        const node = self.nodeAtByte(byte_offset) orelse return null;
        return std.mem.span(ts_node_type(node));
    }

    /// Return the deepest named node that contains `byte_offset`.
    /// Useful for future "expand selection to node" commands.
    pub fn nodeAtByte(self: *const Highlighter, byte_offset: u32) ?TSNode {
        const tree = self.tree orelse return null;
        var node = ts_tree_root_node(tree);
        // Walk down to the deepest named child containing the offset.
        outer: while (true) {
            const count = ts_node_named_child_count(node);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const child = ts_node_named_child(node, i);
                if (ts_node_start_byte(child) <= byte_offset and
                    byte_offset < ts_node_end_byte(child))
                {
                    node = child;
                    continue :outer;
                }
            }
            break;
        }
        return node;
    }
};
