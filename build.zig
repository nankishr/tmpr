const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path(
            "src/c/import.h",
        ),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const is_dev = optimize == .debug;

    const simdjzon_dep = b.dependency("simdjzon", .{
        .target = target,
        .optimize = optimize,
    });

    // zig fmt: off
    const exe = b.addExecutable(.{
        .name = "dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{
                    .name = "c",
                    .module = translate_c.createModule(),
                },
                .{ 
                    .name = "simdjzon", 
                    .module = simdjzon_dep.module("simdjzon")
                },
            },
            .strip = !is_dev
        }),
        .use_llvm = true
    });
    // zig fmt: on

    exe.lto = if (is_dev) .none else .full;

    const miniaudio = b.dependency("miniaudio", .{});
    const libsoxr = b.dependency("libsoxr", .{});

    for ([_]std.Build.LazyPath{ miniaudio.path("."), b.path("src/c"), libsoxr.path("src") }) |path| {
        translate_c.addIncludePath(path);

        exe.root_module.addIncludePath(
            path,
        );
    }

    exe.root_module.addCSourceFile(.{
        .file = miniaudio.path("miniaudio.c"),
        .flags = &.{
            "-std=c99",
            "-O3",
            "-fno-sanitize=undefined",
            "-ffunction-sections",
            "-fdata-sections",
        },
    });

    exe.root_module.addCSourceFiles(.{
        .root = libsoxr.path("src"),
        .files = &.{
            "soxr.c",
            "data-io.c",
            "dbesi0.c",
            "filter.c",
            "cr.c",
            "cr32.c",
            "fft4g32.c",
            "cr64.c",
            "fft4g64.c",
            "vr32.c",
            "cr32s.c",
            "pffft32s.c",
            "util32s.c",
            "cr64s.c",
            "pffft64s.c",
            "util64s.c",
            "pffft.c",
            "pffft-wrap.c",
        },
        .flags = &.{
            "-std=gnu89",
            "-DSOXR_LIB",
            "-msse",
            "-mfpmath=sse",
            "-mavx",
            "-O2",
        },
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();
}
