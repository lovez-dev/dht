const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filter = b.option([]const u8, "test-filter", "Run tests containing this string");
    const library = b.addModule("dht", .{ .root_source_file = b.path("src/dht.zig"), .target = target, .optimize = optimize });
    const checks = b.step("check", "Check formatting and compile every root without running networking");
    const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests"), b.path("examples"), b.path("bench") }, .check = true });
    checks.dependOn(&fmt.step);
    const unit_tests = b.addTest(.{ .name = "dht-unit", .root_module = library, .filters = if (filter) |value| &.{value} else &.{} });
    const run_unit = b.addRunArtifact(unit_tests);
    run_unit.has_side_effects = true;
    var unit_run: ?*std.Build.Step.Run = null;
    for ([_][]const u8{ "test", "integration", "stress" }, [_][]const u8{ "tests/root.zig", "tests/integration.zig", "tests/stress.zig" }) |name, source| {
        const module = consumer(b, source, library, target, optimize);
        const tests = b.addTest(.{ .name = b.fmt("dht-{s}", .{name}), .root_module = module, .filters = if (filter) |value| &.{value} else &.{} });
        const run = b.addRunArtifact(tests);
        run.has_side_effects = true;
        if (std.mem.eql(u8, name, "test")) {
            unit_run = run;
            run.step.dependOn(&run_unit.step);
        }
        if (std.mem.eql(u8, name, "stress")) run.step.dependOn(&unit_run.?.step);
        b.step(name, b.fmt("Run {s} tests", .{name})).dependOn(&run.step);
        const object = b.addTest(.{ .name = b.fmt("check-{s}", .{name}), .root_module = module, .emit_object = true });
        checks.dependOn(&object.step);
    }
    const examples = b.step("examples", "Compile all examples without starting public networking");
    for ([_][]const u8{ "spider", "lookup", "protocol" }) |name| {
        const exe = b.addExecutable(.{ .name = b.fmt("dht-{s}", .{name}), .root_module = consumer(b, b.fmt("examples/{s}.zig", .{name}), library, target, optimize) });
        const install = b.addInstallArtifact(exe, .{});
        examples.dependOn(&install.step);
        if (std.mem.eql(u8, name, "spider")) b.getInstallStep().dependOn(&install.step);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        run.has_side_effects = true;
        b.step(name, b.fmt("Run the {s} example", .{name})).dependOn(&run.step);
        if (std.mem.eql(u8, name, "spider")) b.step("run", "Run the metadata spider").dependOn(&run.step);
        checks.dependOn(&b.addObject(.{ .name = b.fmt("check-{s}", .{name}), .root_module = exe.root_module }).step);
    }
    const server = b.addExecutable(.{ .name = "dht-server", .root_module = consumer(b, "src/main.zig", library, target, optimize) });
    b.installArtifact(server);
    checks.dependOn(&b.addObject(.{ .name = "check-server", .root_module = server.root_module }).step);
    const dependency = b.dependency("zlap", .{ .target = target, .optimize = optimize });
    const bench_module = consumer(b, "bench/main.zig", library, target, optimize);
    bench_module.addImport("zlap", dependency.module("zlap"));
    const bench = b.addExecutable(.{ .name = "dht-bench", .root_module = bench_module });
    const bench_install = b.addInstallArtifact(bench, .{});
    b.step("bench-build", "Install the benchmark without running it").dependOn(&bench_install.step);
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    run_bench.has_side_effects = true;
    const benchmark_csv = run_bench.captureStdOut(.{});
    const benchmark_log = run_bench.captureStdErr(.{});
    const reports = b.addUpdateSourceFiles();
    reports.addCopyFileToSource(benchmark_csv, "out/benchmark.csv");
    reports.addCopyFileToSource(benchmark_log, "out/benchmark.log");
    b.step("bench", "Run offline microbenchmarks and write reports to out/").dependOn(&reports.step);
    checks.dependOn(&b.addObject(.{ .name = "check-bench", .root_module = bench_module }).step);
}
fn consumer(b: *std.Build, source: []const u8, library: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize, .imports = &.{.{ .name = "dht", .module = library }} });
}
