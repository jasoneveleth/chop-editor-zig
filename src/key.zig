// Unified key encoding:
//   0x000000–0x10FFFF  Unicode codepoint (printable chars, already layout/shift resolved by JS)
//   0x110000+          Special keys (above max valid Unicode point)
//   0xFFFFFFFF         Unknown / unhandled

pub const Key = enum(u32) {
    enter       = 0x110000,
    escape      = 0x110001,
    backspace   = 0x110002,
    tab         = 0x110003,
    arrow_left  = 0x110004,
    arrow_right = 0x110005,
    arrow_up    = 0x110006,
    arrow_down  = 0x110007,
    unknown     = 0xFFFFFFFF,
    _, // allow arbitrary codepoint values

    pub fn isPrintable(self: Key) bool {
        return @intFromEnum(self) <= 0x10FFFF;
    }
};

pub const MOD_SHIFT: u32 = 1 << 0;
pub const MOD_CTRL:  u32 = 1 << 1;
pub const MOD_ALT:   u32 = 1 << 2;
pub const MOD_META:  u32 = 1 << 3;
