pub const Op = union(enum) {
    search_forward: ?[]const u8,
    search_backward: ?[]const u8,
    split_selections: ?[]const u8,
    split_selections_complement: ?[]const u8,
    filter_keep: ?[]const u8,
    filter_drop: ?[]const u8,
    preview: PreviewPayload,
    cancel_palette,

    pub const PreviewPayload = struct {
        intent: PaletteOpKind,
        text: []const u8,
    };

    pub const PaletteOpKind = enum {
        search_forward,
        search_backward,
        split_selections,
        split_selections_complement,
        filter_keep,
        filter_drop,
    };
};
