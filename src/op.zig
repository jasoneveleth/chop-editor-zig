pub const Language = enum { zig, none };
pub const Colorscheme = enum { onedark, alabaster };

pub const Op = union(enum) {
    tab_width_palette,
    language_palette,
    colorscheme_palette,
    set_tab_width: u8,
    set_language: Language,
    set_colorscheme: Colorscheme,
    toggle_softwrap,

    pub const PaletteOpKind = enum {
        search_forward,
        search_backward,
        split_selections,
        split_selections_complement,
        filter_keep,
        filter_drop,
        settings_palette,
        tab_width_palette,
        language_palette,
        colorscheme_palette,
    };
};
