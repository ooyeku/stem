const std = @import("std");

pub fn installPlugin(b: *std.Build, lib: *std.Build.Step.Compile) void {
    var install_step = b.getInstallStep();

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
