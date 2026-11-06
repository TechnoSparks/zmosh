const std = @import("std");
const Translator = @import("translate_c").Translator;
const build_zig_zon = @import("build.zig.zon");

const linux_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
};

const macos_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version string for release") orelse
        @as([]const u8, build_zig_zon.version);

    const translate_c = b.dependency("translate_c", .{});
    const translator: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });

    const zmx = b.dependency("zmx", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{
                .name = "cross",
                .module = translator.mod,
            },
        },
    });
    exe_mod.addImport("libzmx", zmx.module("zmx"));
    exe_mod.addImport("zmx", zmx.module("zmx"));

    const exe = b.addExecutable(.{
        .name = "zmosh",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run zmosh").dependOn(&run_cmd.step);

    // Test step
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{
                .name = "cross",
                .module = translator.mod,
            },
        },
    });
    test_mod.addImport("libzmx", zmx.module("zmx"));
    test_mod.addImport("zmx", zmx.module("zmx"));

    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    // Check step (for ZLS / editor diagnostics)
    const check_exe = b.addExecutable(.{
        .name = "zmosh-check",
        .root_module = exe_mod,
    });
    b.step("check", "Check if zmosh compiles").dependOn(&check_exe.step);

    // Android Shared Library build step: builds libzmosh.so for Android ABIs
    {
        const android_step = b.step("android-lib", "Build libzmosh.so for Android ABIs");
        const android_targets = [_]struct {
            query: std.Target.Query,
            abi: []const u8,
        }{
            .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl }, .abi = "arm64-v8a" },
            .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .abi = "x86_64" },
            .{ .query = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .musleabihf }, .abi = "armeabi-v7a" },
        };
        for (android_targets) |target_info| {
            const resolved = b.resolveTargetQuery(target_info.query);

            const lib_mod = b.createModule(.{
                .root_source_file = b.path("src/c_api.zig"),
                .target = resolved,
                .optimize = optimize,
                .link_libc = true,
            });

            const lib = b.addLibrary(.{
                .name = "zmosh",
                .root_module = lib_mod,
                .linkage = .dynamic,
            });

            const install_lib = b.addInstallArtifact(lib, .{
                .dest_dir = .{ .override = .{ .custom = b.fmt("android/{s}", .{target_info.abi}) } },
            });
            android_step.dependOn(&install_lib.step);
        }
    }

    // Multi-platform release step
    {
        const release_step = b.step(
            "release",
            "Build release binaries for all platforms",
        );
        const release_targets = linux_targets ++ macos_targets;
        for (release_targets) |release_target| {
            const resolved = b.resolveTargetQuery(release_target);
            const rel_translator: Translator = .init(translate_c, .{
                .c_source_file = b.path("src/c.h"),
                .target = resolved,
                .optimize = .ReleaseSafe,
            });

            const rel_zmx = b.dependency("zmx", .{
                .target = resolved,
                .optimize = .ReleaseSafe,
            });

            const release_mod = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
                .link_libc = true,
                .imports = &.{
                    .{
                        .name = "cross",
                        .module = rel_translator.mod,
                    },
                },
            });
            release_mod.addImport("libzmx", rel_zmx.module("zmx"));
            release_mod.addImport("zmx", rel_zmx.module("zmx"));

            const release_exe = b.addExecutable(.{
                .name = "zmosh",
                .root_module = release_mod,
            });

            const os_name = @tagName(release_target.os_tag orelse .linux);
            const arch_name = @tagName(release_target.cpu_arch orelse .x86_64);
            const tarball_name = b.fmt("zmosh-{s}-{s}-{s}.tar.gz", .{ version, os_name, arch_name });

            const tar = b.addSystemCommand(&.{ "tar", "-czf" });
            const tarball = tar.addOutputFileArg(tarball_name);
            tar.addArg("-C");
            tar.addDirectoryArg(release_exe.getEmittedBinDirectory());
            tar.addArg("zmosh");

            const shasum = b.addSystemCommand(&.{"sha256sum"});
            shasum.addFileArg(tarball);
            const shasum_output = shasum.captureStdOut(.{});

            const install_tar = b.addInstallFile(tarball, b.fmt("dist/{s}", .{tarball_name}));
            const install_sha = b.addInstallFile(
                shasum_output,
                b.fmt("dist/{s}.sha256", .{tarball_name}),
            );
            release_step.dependOn(&install_tar.step);
            release_step.dependOn(&install_sha.step);
        }
    }
}
