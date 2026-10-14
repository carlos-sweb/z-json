const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zvalue_dep = b.dependency("zvalue", .{ .target = target, .optimize = optimize });
    const znumber_dep = b.dependency("znumber", .{ .target = target, .optimize = optimize });
    const zbuffer_dep = b.dependency("zbuffer", .{ .target = target, .optimize = optimize });
    const zvalue_module = zvalue_dep.module("zvalue");
    const znumber_module = znumber_dep.module("znumber");
    const zbuffer_module = zbuffer_dep.module("zbuffer");

    const zjson_module = b.addModule("zjson", .{
        .root_source_file = b.path("src/zjson.zig"),
        .target = target,
        .optimize = optimize,
    });
    zjson_module.addImport("zvalue", zvalue_module);
    zjson_module.addImport("znumber", znumber_module);
    zjson_module.addImport("zbuffer", zbuffer_module);

    const docs_library = b.addLibrary(.{
        .name = "zjson",
        .root_module = zjson_module,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate Zig API documentation");
    docs_step.dependOn(&install_docs.step);

    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{
        "tests/stringify_test.zig",
        "tests/parse_test.zig",
        "tests/roundtrip_test.zig",
    };

    inline for (test_files) |test_file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
            }),
        });

        unit_tests.root_module.addImport("zjson", zjson_module);
        unit_tests.root_module.addImport("zvalue", zvalue_module);
        unit_tests.root_module.addImport("zbuffer", zbuffer_module);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    // Also run the tests inlined in src/zjson.zig itself.
    const src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zjson.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    src_tests.root_module.addImport("zvalue", zvalue_module);
    src_tests.root_module.addImport("znumber", znumber_module);
    src_tests.root_module.addImport("zbuffer", zbuffer_module);
    const run_src_tests = b.addRunArtifact(src_tests);
    test_step.dependOn(&run_src_tests.step);

    b.default_step = test_step;
}
