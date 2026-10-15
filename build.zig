//! zig build            → zig-out/bin/seek (CLI) and zig-out/lib/libseek.a + include/seek.h
//! zig build test       → Zig unit tests + a C program exercising the C API
//! zig build app        → zig-out/Seek.app (macOS only; needs Xcode Command Line Tools)
//! zig build run-app    → build and launch Seek.app
//!
//! Quality harness (see README "Quality checks"):
//! zig build check      → fmt-check + lint + objc-check + test + netcheck   (run before every commit)
//! zig build check-deep → check + tests in ReleaseSafe + tests under ThreadSanitizer
//! zig build fmt        → rewrite Zig sources into canonical format

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
    const test_step = b.step("test", "Run unit tests and the C API test");
    test_step.dependOn(addTestSuite(b, "suite", target, optimize, false));
    const safe_step = b.step("test-safe", "Run the tests in ReleaseSafe (runtime safety checks on)");
    safe_step.dependOn(addTestSuite(b, "suite-safe", target, .ReleaseSafe, false));
    const tsan_step = b.step("test-tsan", "Run the tests under ThreadSanitizer (search and scan run concurrently)");
    tsan_step.dependOn(addTestSuite(b, "suite-tsan", target, optimize, true));

    // ---- formatting and lint
    const fmt_paths: []const std.Build.LazyPath = &.{ b.path("src"), b.path("build.zig"), b.path("build.zig.zon") };
    const fmt_step = b.step("fmt", "Rewrite Zig sources into canonical format");
    fmt_step.dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);
    const fmt_check = b.step("fmt-check", "Fail if any Zig source is not formatted");
    fmt_check.dependOn(&b.addFmt(.{ .paths = fmt_paths, .check = true }).step);

    const lint_step = b.step("lint", "Project lint rules (tools/lint.sh)");
    lint_step.dependOn(&b.addSystemCommand(&.{"tools/lint.sh"}).step);

    // ---- Seek.app (macOS): AppKit shell compiled with Apple's clang, linked to libseek.a
    const app_step = b.step("app", "Build zig-out/Seek.app (macOS)");
    const run_app_step = b.step("run-app", "Build and launch Seek.app (macOS)");
    const objc_check = b.step("objc-check", "Compile the AppKit shell with -Werror and run the clang static analyzer (macOS)");
    const netcheck_step = b.step("netcheck", "Verify the built binaries import no networking APIs (macOS)");
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
            "xcrun",             "clang",      "-fobjc-arc",                "-fmodules",
            "-O2",               "-Wall",      "-mmacosx-version-min=13.0", "-framework",
            "AppKit",            "-framework", "Carbon",                    "-framework",
            "ServiceManagement", "-lsqlite3",
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

        // Static checks on the AppKit shell: all warnings are errors, plus the clang static analyzer.
        const objc_flags = [_][]const u8{ "-fobjc-arc", "-fmodules", "-mmacosx-version-min=13.0", "-Iinclude", "macos/SeekApp.m" };
        const objc_warn = b.addSystemCommand(&.{ "xcrun", "clang", "-fsyntax-only", "-Wall", "-Wextra", "-Wno-unused-parameter", "-Werror" });
        objc_warn.addArgs(&objc_flags);
        const objc_analyze = b.addSystemCommand(&.{ "xcrun", "clang", "--analyze", "-Xanalyzer", "-analyzer-werror", "-o", "/dev/null" });
        objc_analyze.addArgs(&objc_flags);
        objc_check.dependOn(&objc_warn.step);
        objc_check.dependOn(&objc_analyze.step);

        // The offline promise, checked on the real binaries.
        const net = b.addSystemCommand(&.{ "tools/netcheck.sh", "zig-out/Seek.app/Contents/MacOS/Seek", "zig-out/bin/seek" });
        net.step.dependOn(&sign.step);
        net.step.dependOn(b.getInstallStep());
        netcheck_step.dependOn(&net.step);
    } else {
        const fail = b.addFail("Seek.app builds on macOS only (use `zig build` for the CLI here)");
        app_step.dependOn(&fail.step);
        run_app_step.dependOn(&fail.step);
    }

    // ---- everything, in the order a failure is cheapest to find
    const check = b.step("check", "Run every quality check (run before committing)");
    check.dependOn(fmt_check);
    check.dependOn(lint_step);
    if (is_macos) {
        check.dependOn(objc_check);
        check.dependOn(netcheck_step);
    }
    check.dependOn(test_step);

    const deep = b.step("check-deep", "check, plus ReleaseSafe and ThreadSanitizer test runs");
    deep.dependOn(check);
    deep.dependOn(safe_step);
    deep.dependOn(tsan_step);
}

/// Unit tests (core + C API) and the C program that drives the C API, built with the given
/// optimize mode, optionally under ThreadSanitizer. Returns a step that runs both.
fn addTestSuite(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, tsan: bool) *std.Build.Step {
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_thread = if (tsan) true else null,
    });
    const lib = b.addLibrary(.{ .name = "seek", .linkage = .static, .root_module = lib_mod });
    lib.bundle_compiler_rt = true;

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_thread = if (tsan) true else null,
    });
    test_mod.linkSystemLibrary("sqlite3", .{});
    const unit = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));

    const ctest_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .sanitize_thread = if (tsan) true else null });
    ctest_mod.addCSourceFile(.{ .file = b.path("tests/capi_test.c") });
    ctest_mod.addIncludePath(b.path("include"));
    ctest_mod.linkLibrary(lib);
    ctest_mod.linkSystemLibrary("sqlite3", .{});
    const ctest = b.addRunArtifact(b.addExecutable(.{ .name = "capi_test", .root_module = ctest_mod }));
    ctest.addDirectoryArg(b.path("src")); // a real folder to index

    const group = b.step(name, "");
    group.dependOn(&unit.step);
    group.dependOn(&ctest.step);
    return group;
}
