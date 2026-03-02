const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
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

    // Output goes to web/editor.wasm
    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "../web" } },
    });
    b.getInstallStep().dependOn(&install.step);
}
