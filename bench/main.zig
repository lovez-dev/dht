const std = @import("std");
const bench = @import("zlap");
const dht = @import("dht");

var table: dht.RoutingTable = undefined;
var large_table: dht.RoutingTable = undefined;
var crawl_table: dht.RoutingTable = undefined;
var targets: [256]dht.NodeId = undefined;
var metadata: [16 * 1024]u8 = undefined;
var metadata_hash: [20]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var count_allocations = false;
    var measure_memory = false;
    var case_filter: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--allocations")) {
            count_allocations = true;
        } else if (std.mem.eql(u8, arg, "--memory")) {
            measure_memory = true;
        } else if (std.mem.startsWith(u8, arg, "--case=")) {
            case_filter = arg[7..];
        } else return error.UnknownArgument;
    }
    if (measure_memory) return routingMemory();
    const config: bench.Config = .{
        .allocator = std.heap.smp_allocator,
        .batch_size = 256,
        .rounds = 3,
        .sample_count = 20,
        .min_sample_ns = 2_000_000,
        .count_allocations = count_allocations,
    };
    table = dht.RoutingTable.init(std.heap.smp_allocator, 8, 1024);
    defer table.deinit();
    // Fixed fixtures make before/after runs comparable.
    var prng = std.Random.DefaultPrng.init(0x646874);
    const random = prng.random();
    for (&targets) |*target| random.bytes(target);
    for (0..512) |i| {
        var id: dht.NodeId = undefined;
        random.bytes(&id);
        _ = try table.insert(.{ .id = id, .address = .{ .ip = .{ .v4 = .{ 8, 8, @intCast(i / 256), @truncate(i) } }, .port = 6881 } });
    }
    large_table = dht.RoutingTable.init(std.heap.smp_allocator, 8, 5000);
    defer large_table.deinit();
    for (0..5000) |i| {
        var id: dht.NodeId = undefined;
        random.bytes(&id);
        _ = try large_table.insert(.{ .id = id, .address = .{ .ip = .{ .v4 = .{ 8, 9, @intCast(i / 256), @truncate(i) } }, .port = 6881 } });
    }
    crawl_table = dht.RoutingTable.init(std.heap.smp_allocator, std.math.maxInt(usize), 5000);
    defer crawl_table.deinit();
    for (large_table.nodes.items) |node| _ = try crawl_table.insert(node);
    random.bytes(&metadata);
    std.crypto.hash.Sha1.hash(&metadata, &metadata_hash, .{});
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll("case,mode,operations,mean_ns,median_ns,p95_batch_ns,cv,allocations_measured,requested_bytes_per_op\n");
    inline for (.{
        .{ "bencode_parse_ping", parse },
        .{ "krpc_handle_ping", ping },
        .{ "krpc_find_node_512", findNode },
        .{ "routing_closest_8_of_512", closest },
        .{ "routing_closest_64_of_5000", closestLarge },
        .{ "routing_crawl_closest_8_of_5000", closestCrawl },
        .{ "routing_update_5000", updateNode },
        .{ "routing_crawl_update_5000", updateCrawlNode },
        .{ "routing_churn_5000", churnNode },
        .{ "routing_build_512", buildTable },
        .{ "transaction_register_complete_retire", transaction },
        .{ "metadata_16k_assemble_sha1", assemble },
    }) |case| {
        if (case_filter == null or std.mem.eql(u8, case_filter.?, case[0])) {
            var case_config = config;
            // Each sample visits every node, even if calibration selects a
            // different number of operations on the two versions.
            if (comptime std.mem.eql(u8, case[0], "routing_update_5000") or
                std.mem.eql(u8, case[0], "routing_crawl_update_5000") or
                std.mem.eql(u8, case[0], "routing_churn_5000"))
            {
                case_config.batch_size = 5000;
                case_config.batch_repeats = 1;
                case_config.rounds = 1;
                case_config.sample_count = 10;
            }
            if (comptime std.mem.eql(u8, case[0], "routing_build_512")) {
                case_config.batch_size = 1;
                case_config.rounds = 1;
                case_config.sample_count = 10;
            }
            const result = try bench.runConfigured(init.io, case_config, case[1]);
            result.print(case[0]);
            try output.interface.print("{s},{s},{d},{d:.3},{d:.3},{d:.3},{d:.6},{},{d:.3}\n", .{
                case[0],                     @tagName(@import("builtin").mode),                                                             result.operations, result.mean(), result.median(), result.percentile(95), result.coefficientOfVariation(),
                result.allocations_measured, @as(f64, @floatFromInt(result.allocation_bytes)) / @as(f64, @floatFromInt(result.operations)),
            });
        }
    }
    try output.interface.flush();
}

fn routingMemory() !void {
    inline for (.{ 512, 5000 }) |count| {
        inline for (.{ false, true }) |crawl| {
            // With failure disabled this allocator tracks requested live
            // bytes including resize/remap; it does not measure process RSS.
            var counter = std.testing.FailingAllocator.init(std.heap.smp_allocator, .{});
            var fixture = dht.RoutingTable.init(counter.allocator(), if (crawl) std.math.maxInt(usize) else 8, count);
            {
                defer fixture.deinit();
                var prng = std.Random.DefaultPrng.init(0x646874);
                for (0..count) |i| {
                    var id: dht.NodeId = undefined;
                    prng.random().bytes(&id);
                    _ = try fixture.insert(.{ .id = id, .address = .{ .ip = .{ .v4 = .{ 8, 9, @intCast(i / 256), @truncate(i) } }, .port = 6881 } });
                }
                std.debug.print("routing count={d} crawl={} live_requested_bytes={d}\n", .{ count, crawl, counter.allocated_bytes - counter.freed_bytes });
            }
            if (counter.allocated_bytes != counter.freed_bytes) return error.LeakedFixture;
        }
    }
}

fn parse(allocator: std.mem.Allocator, operations: usize) !void {
    for (0..operations) |_| {
        var value = try dht.bencode.Parser.parse(allocator, "d1:ad2:id20:abcdefghijklmnopqrste1:q4:ping1:t2:aa1:y1:qe");
        defer value.deinit(allocator);
        std.mem.doNotOptimizeAway(&value);
    }
}

fn ping(allocator: std.mem.Allocator, operations: usize) !void {
    var server = dht.Server.init(allocator, targets[0]);
    defer server.deinit();
    var prng = std.Random.DefaultPrng.init(1);
    var random = prng.random();
    var output: [512]u8 = undefined;
    for (0..operations) |_| {
        const response = try server.handleDatagram(&random, .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = 6881 }, 0, "d1:ad2:id20:abcdefghijklmnopqrste1:q4:ping1:t2:aa1:y1:qe", &output);
        std.mem.doNotOptimizeAway(response);
    }
}
fn closest(_: std.mem.Allocator, operations: usize) !void {
    var output: [8]dht.Node = undefined;
    for (0..operations) |i| {
        const result = table.closest(targets[i % targets.len], &output);
        std.mem.doNotOptimizeAway(result);
    }
}
fn updateNode(_: std.mem.Allocator, operations: usize) !void {
    for (0..operations) |i| {
        var node = large_table.nodes.items[i % large_table.nodes.items.len];
        node.last_active_ms = @intCast(i);
        std.mem.doNotOptimizeAway(try large_table.insert(node));
    }
}
fn closestLarge(_: std.mem.Allocator, operations: usize) !void {
    var output: [64]dht.Node = undefined;
    for (0..operations) |i| {
        std.mem.doNotOptimizeAway(large_table.closest(targets[i % targets.len], &output));
    }
}
fn closestCrawl(_: std.mem.Allocator, operations: usize) !void {
    var output: [8]dht.Node = undefined;
    for (0..operations) |i| {
        std.mem.doNotOptimizeAway(crawl_table.closest(targets[i % targets.len], &output));
    }
}
fn findNode(allocator: std.mem.Allocator, operations: usize) !void {
    var server = dht.Server.init(allocator, targets[0]);
    defer server.deinit();
    for (table.nodes.items) |node| _ = try server.table.insert(node);
    var prng = std.Random.DefaultPrng.init(1);
    var random = prng.random();
    var output: [1024]u8 = undefined;
    for (0..operations) |i| {
        var input: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&input);
        try writer.writeAll("d1:ad2:id20:");
        try writer.writeAll(&table.nodes.items[0].id);
        try writer.writeAll("6:target20:");
        try writer.writeAll(&targets[i % targets.len]);
        try writer.writeAll("e1:q9:find_node1:t2:aa1:y1:qe");
        const response = try server.handleDatagram(&random, table.nodes.items[0].address, 0, writer.buffered(), &output);
        std.mem.doNotOptimizeAway(response);
    }
}
fn updateCrawlNode(_: std.mem.Allocator, operations: usize) !void {
    for (0..operations) |i| {
        var node = crawl_table.nodes.items[i % crawl_table.nodes.items.len];
        node.last_active_ms = @intCast(i);
        std.mem.doNotOptimizeAway(try crawl_table.insert(node));
    }
}
fn churnNode(_: std.mem.Allocator, operations: usize) !void {
    // A separate immutable fixture gives both implementations identical IDs
    // even when removal changes the flattened iteration order.
    for (0..operations) |i| {
        const node = crawl_table.nodes.items[i % crawl_table.nodes.items.len];
        if (!large_table.remove(node.id)) return error.MissingContact;
        if (!try large_table.insert(node)) return error.MissingContact;
    }
}
fn buildTable(allocator: std.mem.Allocator, operations: usize) !void {
    for (0..operations) |_| {
        var fresh = dht.RoutingTable.init(allocator, 8, 512);
        defer fresh.deinit();
        for (table.nodes.items) |node| _ = try fresh.insert(node);
        std.mem.doNotOptimizeAway(&fresh);
    }
}
fn transaction(allocator: std.mem.Allocator, operations: usize) !void {
    var manager = dht.TransactionManager.init(allocator, std.math.maxInt(u32));
    defer manager.deinit();
    var expired: std.ArrayList(dht.TransactionManager.Pending) = .empty;
    defer expired.deinit(allocator);
    var retry: std.ArrayList(dht.TransactionManager.Pending) = .empty;
    defer retry.deinit(allocator);
    const address: dht.Address = .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = 6881 };
    for (0..operations) |i| {
        const id = manager.next();
        const now_ms: i64 = @intCast(i * 15000);
        try manager.register(id, .{ .address = address, .query = .get_peers, .target = targets[i % targets.len], .created_ms = now_ms });
        std.mem.doNotOptimizeAway(manager.take(id, address));
        try manager.retryOrExpire(now_ms + 15000, 15000, 2, &expired, &retry);
    }
}
fn assemble(allocator: std.mem.Allocator, operations: usize) !void {
    for (0..operations) |_| {
        var assembler = try dht.peerwire.MetadataAssembler.init(allocator, metadata_hash, metadata.len);
        defer assembler.deinit();
        try assembler.put(0, &metadata);
        const result = try assembler.finalize();
        defer allocator.free(result);
        std.mem.doNotOptimizeAway(result);
    }
}
