const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the plugin as a dynamic library
    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "plugin_manager",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add the stem plugin SDK module
    const stem_module = b.addModule("stem", .{
        .root_source_file = b.path("../../../src/stem_plugin.zig"),
    });

    // Use dependencies from build.zig.zon (same as main stem project)
    const vigil_dep = b.dependency("vigil", .{
        .target = target,
        .optimize = optimize,
    });
    stem_module.addImport("vigil", vigil_dep.module("vigil"));

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    stem_module.addImport("vaxis", vaxis_dep.module("vaxis"));

    // Add stem import to the library
    lib.root_module.addImport("stem", stem_module);

    // Install to ~/.stem/plugins/
    installPlugin(b, lib);
}

/// Helper to install a plugin to the local ~/.stem/plugins directory
fn installPlugin(b: *std.Build, lib: *std.Build.Step.Compile) void {
    const install_step = b.getInstallStep();

    const env_map = std.process.getEnvMap(b.allocator) catch return;
    const home = env_map.get("HOME") orelse ".";

    const plugin_dir = std.fs.path.join(b.allocator, &[_][]const u8{ home, ".stem", "plugins" }) catch @panic("OOM");

    const mkdir_cmd = b.addSystemCommand(&[_][]const u8{ "mkdir", "-p", plugin_dir });

    const copy_cmd = b.addSystemCommand(&[_][]const u8{"cp"});
    copy_cmd.addArtifactArg(lib);
    copy_cmd.addArg(plugin_dir);

    copy_cmd.step.dependOn(&mkdir_cmd.step);

    install_step.dependOn(&copy_cmd.step);
}
