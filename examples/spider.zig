const std = @import("std");
const dht = @import("dht");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const port = if (args.len == 2) try std.fmt.parseInt(u16, args[1], 10) else @as(u16, 6881);
    var seed: [32]u8 = undefined;
    try init.io.randomSecure(&seed);
    var prng = std.Random.DefaultCsprng.init(seed);
    const random = prng.random();
    var wire = dht.Wire.initWithConfig(allocator, init.io, random, .{
        .blacklist_capacity = 65_536,
        .request_queue_capacity = 1_024,
        .worker_limit = 256,
        .response_queue_capacity = 1_024,
    });
    var tasks: std.Io.Group = .init;
    try tasks.concurrent(init.io, dht.Wire.run, .{&wire});
    try tasks.concurrent(init.io, consumeResponses, .{ &wire, init.io });
    var crawler = dht.Dht.init(allocator, init.io, .{ .port = port, .on_announce_peer = onAnnounce, .context = &wire }, random) catch |err| {
        std.log.err("bind :{d} {s}", .{ port, @errorName(err) });
        wire.stop();
        tasks.cancel(init.io);
        wire.deinit();
        return;
    };
    defer crawler.deinit();
    defer wire.deinit();
    defer {
        wire.stop();
        tasks.cancel(init.io);
    }
    try tasks.concurrent(init.io, reportStats, .{ &crawler, &wire, init.io });
    try crawler.run(init.io);
}

fn reportStats(crawler: *dht.Dht, wire: *dht.Wire, io: std.Io) std.Io.Cancelable!void {
    while (true) {
        try io.sleep(.fromSeconds(10), .awake);
        const node = crawler.stat();
        const metadata = wire.stat();
        std.log.info("nodes={d} pending={d} sent={d} received={d} dropped={d} metadata_queued={d} active={d} completed={d} failed={d}", .{
            node.nodes,           node.pending_queries, node.sent_packets, node.received_packets,
            node.dropped_packets, metadata.queued,      metadata.active,   metadata.completed,
            metadata.failed,
        });
    }
}

fn onAnnounce(context: ?*anyopaque, info_hash: dht.NodeId, peer: dht.Address) void {
    const wire: *dht.Wire = @ptrCast(@alignCast(context.?));
    wire.tryRequest(info_hash, peer) catch |err| switch (err) {
        error.Blacklisted, error.QueueFull => {},
        else => std.log.warn("metadata {s}", .{@errorName(err)}),
    };
}

fn consumeResponses(wire: *dht.Wire, io: std.Io) std.Io.Cancelable!void {
    var output_buffer: [64 * 1024]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(io, &output_buffer);
    while (true) {
        const response = (try wire.waitResponseCancelable()) orelse return;
        defer std.heap.smp_allocator.free(response.metadata);
        printMetadata(&output_writer.interface, response.info_hash, response.metadata) catch |err| {
            std.log.warn("metadata output {s}", .{@errorName(err)});
        };
    }
}

fn printMetadata(writer: *std.Io.Writer, info_hash: dht.NodeId, metadata: []const u8) !void {
    // Metadata is only decoded to derive this log line. Its parse tree is
    // released as one temporary allocation batch after the callback returns.
    var metadata_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer metadata_arena.deinit();
    var value = dht.bencode.Parser.parse(metadata_arena.allocator(), metadata) catch return;
    if (value != .dict) return;
    const name: []const u8 = if (value.get("name")) |item| if (item.* == .bytes) item.bytes else "?" else "?";

    try writer.writeAll("\n{\"infohash\":");
    try writer.print("\"{x}\"", .{info_hash});
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, name);
    if (value.get("length")) |length| {
        if (length.* == .integer) {
            try writer.print(",\"length\":{d}}}\n", .{length.integer});
            try writer.flush();
            return;
        }
    }
    if (value.get("files")) |files| {
        if (files.* == .list) {
            try writer.writeAll(",\"files\":[");
            var first = true;
            for (files.list.items) |file| {
                if (file != .dict) continue;
                const length = file.get("length") orelse continue;
                if (length.* != .integer) continue;
                if (!first) try writer.writeByte(',');
                first = false;
                try writer.writeAll("{\"path\":[");
                if (file.get("path")) |path| if (path.* == .list) {
                    var first_path = true;
                    for (path.list.items) |component| {
                        if (component != .bytes) continue;
                        if (!first_path) try writer.writeByte(',');
                        first_path = false;
                        try writeJsonString(writer, component.bytes);
                    }
                };
                try writer.print("],\"length\":{d}}}", .{length.integer});
            }
            try writer.writeAll("]}\n");
            try writer.flush();
            return;
        }
    }
    try writer.writeAll("}\n");
    try writer.flush();
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    var stringify: std.json.Stringify = .{ .writer = writer };
    try stringify.write(value);
}
