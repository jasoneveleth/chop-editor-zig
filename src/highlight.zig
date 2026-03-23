pub const Tag = enum(u8) {
    default,
    keyword,
    string,
    comment,
    number,
    builtin,
    identifier,
    identifier_decl,   // identifier under var_decl / param_decl
    punctuation,
};

pub const Span = struct {
    start: u32,
    end: u32,
    tag: Tag,
};
