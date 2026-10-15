//! zig build            → zig-out/bin/seek (CLI) and zig-out/lib/libseek.a + include/seek.h
//! zig build test       → Zig unit tests + a C program exercising the C API
//! zig build app        → zig-out/Seek.app (macOS only; needs Xcode Command Line Tools)
//! zig build run-app    → build and launch Seek.app

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_macos = target.result.os.tag == .macos;
    // Ad-hoc signing ("-") changes the app's identity on every build, so macOS re-asks for
    // folder access. A self-signed certificate keeps it stable: -Dsign="Seek Dev" (see README).
    const sign_identity = b.option([]const u8, "sign", "Code-signing identity for Seek.app (default: ad-hoc)") orelse "-";

    // ---- libseek: the core, with a C ABI
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{ .name = "seek", .linkage = .static, .root_module = lib_mod });
    lib.bundle_compiler_rt = true;
    lib.installHeader(b.path("include/seek.h"), "seek.h");
    b.installArtifact(lib);

    // ---- seek CLI
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.linkSystemLibrary("sqlite3", .{});
    const exe = b.addExecutable(.{ .name = "seek", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the seek CLI").dependOn(&run.step);

    // ---- tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.linkSystemLibrary("sqlite3", .{});
    const unit = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));

    const ctest_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    ctest_mod.addCSourceFile(.{ .file = b.path("tests/capi_test.c") });
    ctest_mod.addIncludePath(b.path("include"));
    ctest_mod.linkLibrary(lib);
    ctest_mod.linkSystemLibrary("sqlite3", .{});
    const ctest = b.addRunArtifact(b.addExecutable(.{ .name = "capi_test", .root_module = ctest_mod }));
    ctest.addDirectoryArg(b.path("src")); // a real folder to index

    const test_step = b.step("test", "Run unit tests and the C API test");
    test_step.dependOn(&unit.step);
    test_step.dependOn(&ctest.step);

    // ---- Seek.app (macOS): AppKit shell compiled with Apple's clang, linked to libseek.a
    const app_step = b.step("app", "Build zig-out/Seek.app (macOS)");
    const run_app_step = b.step("run-app", "Build and launch Seek.app (macOS)");
    if (is_macos) {
        // libseek built for the app's deployment target, so it links without
        // "built for newer macOS version" warnings.
        var app_query = target.query;
        app_query.os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } };
        const app_lib = b.addLibrary(.{
            .name = "seek",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/capi.zig"),
                .target = b.resolveTargetQuery(app_query),
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        app_lib.bundle_compiler_rt = true;

        const cc = b.addSystemCommand(&.{
            "xcrun",       "clang",           "-fobjc-arc",       "-fmodules",
            "-O2",         "-Wall",           "-mmacosx-version-min=13.0",
            "-framework",  "AppKit",          "-framework",       "Carbon",
            "-framework",  "ServiceManagement", "-lsqlite3",
        });
        cc.addPrefixedDirectoryArg("-I", b.path("include"));
        cc.addFileArg(b.path("macos/SeekApp.m"));
        cc.addArtifactArg(app_lib);
        cc.addArg("-o");
        const bin = cc.addOutputFileArg("Seek");

        const inst_bin = b.addInstallFile(bin, "Seek.app/Contents/MacOS/Seek");
        const inst_plist = b.addInstallFile(b.path("macos/Info.plist"), "Seek.app/Contents/Info.plist");

        const app_dir: std.Build.LazyPath = .{ .relative = .{ .base = .install_prefix, .sub_path = "Seek.app" } };
        // Sign the bundle so macOS treats it as one app.
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", sign_identity });
        sign.addDirectoryArg(app_dir);
        sign.step.dependOn(&inst_bin.step);
        sign.step.dependOn(&inst_plist.step);
        app_step.dependOn(&sign.step);

        const open = b.addSystemCommand(&.{"open"});
        open.addDirectoryArg(app_dir);
        open.step.dependOn(&sign.step);
        run_app_step.dependOn(&open.step);
    } else {
        const fail = b.addFail("Seek.app builds on macOS only (use `zig build` for the CLI here)");
        app_step.dependOn(&fail.step);
        run_app_step.dependOn(&fail.step);
    }
}
