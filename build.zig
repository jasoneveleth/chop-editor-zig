const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "editor",
        .root_module = root_module,
    });

    exe.entry = .disabled;
    exe.rdynamic = true; // export symbols to JS
    exe.linkLibC();

    // ── Tree-sitter ────────────────────────────────────────────────────────────
    // Vendor setup (run once):
    //   git clone --depth 1 https://github.com/tree-sitter/tree-sitter   vendor/tree-sitter
    //   git clone --depth 1 https://github.com/maxxnino/tree-sitter-zig  vendor/tree-sitter-zig

    exe.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    exe.addIncludePath(b.path("vendor/tree-sitter/lib/src")); // for unicode/ subdir

    exe.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/lib/src/lib.c"),
        .flags = &.{ "-std=c11", "-fno-sanitize=all", "-D_POSIX_C_SOURCE=200809L" },
    });
    exe.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter-zig/src/parser.c"),
        .flags = &.{ "-std=c99", "-fno-sanitize=all" },
    });

    // Output goes to web/editor.wasm
    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "../web" } },
    });
    b.getInstallStep().dependOn(&install.step);
}
