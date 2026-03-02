const draw = @import("../draw.zig");

// JS-provided drawing functions. All imported from the "env" module by default
// in freestanding WASM. The JS host must supply these in the imports object.
extern fn js_fill_rect(x: f32, y: f32, w: f32, h: f32, color: u32) void;
extern fn js_draw_text(x: f32, y: f32, ptr: [*]const u8, len: u32, color: u32, size: f32) void;
// Separate from fill_rect so JS can apply blink, I-beam shape, or other cursor styling.
extern fn js_draw_cursor(x: f32, y: f32, w: f32, h: f32, color: u32) void;
extern fn js_clip_rect(x: f32, y: f32, w: f32, h: f32) void;
extern fn js_clear_clip() void;
// Called during layout so the editor can know how wide a string will render.
// JS uses ctx.measureText() and returns the width in pixels.
extern fn js_measure_text(ptr: [*]const u8, len: u32, size: f32) f32;

pub fn present(dl: *const draw.DrawList) void {
    for (dl.cmds.items) |cmd| {
        switch (cmd) {
            .fill_rect => |r| js_fill_rect(
                r.rect.x, r.rect.y, r.rect.w, r.rect.h,
                r.color.toU32(),
            ),
            .draw_text => |t| js_draw_text(
                t.x, t.y,
                t.text.ptr, @intCast(t.text.len),
                t.color.toU32(), t.size,
            ),
            .draw_cursor => |c| js_draw_cursor(
                c.rect.x, c.rect.y, c.rect.w, c.rect.h,
                c.color.toU32(),
            ),
            .clip_rect => |r| js_clip_rect(r.x, r.y, r.w, r.h),
            .clear_clip => js_clear_clip(),
        }
    }
}

pub fn measureText(text: []const u8, size: f32) f32 {
    return js_measure_text(text.ptr, @intCast(text.len), size);
}
