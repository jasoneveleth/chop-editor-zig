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
    type_primitive,    // BuildinTypeExpr: usize, u8, bool, void, f32, etc.
    fn_name,           // function declaration name or call site
};

pub const Span = struct {
    start: u32,
    end: u32,
    tag: Tag,
};
