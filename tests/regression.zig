const std = @import("std");
const dht = @import("dht");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const address: dht.Address = .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = 6881 };

test "node responses preserve nearest order for mixed IPv4 and IPv6 contacts" {
    var server = dht.Server.init(a, @splat(255));
    defer server.deinit();
    var prng = std.Random.DefaultPrng.init(17);
    var random = prng.random();
    for (0..12) |i| {
        const distance: u8 = @intCast(12 - i);
        var id: dht.NodeId = @splat(0);
        id[19] = distance;
        var ip6: [16]u8 = @splat(0);
        ip6[0] = 0x20;
        ip6[1] = 1;
        ip6[15] = distance;
        _ = try server.table.insert(.{ .id = id, .address = .{
            .ip = if (distance % 2 == 0) .{ .v6 = ip6 } else .{ .v4 = .{ 8, 8, 8, distance } },
            .port = 6881,
        } });
    }
    inline for (.{ "find_node", "get_peers" }) |query| {
        var input: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&input);
        try writer.writeAll("d1:ad2:id20:");
        try writer.writeAll(&server.id);
        try writer.writeAll(if (comptime std.mem.eql(u8, query, "find_node")) "6:target20:" else "9:info_hash20:");
        try writer.writeAll(&@as(dht.NodeId, @splat(0)));
        try writer.writeAll("e1:q9:" ++ query ++ "1:t2:aa1:y1:qe");
        var output: [1024]u8 = undefined;
        const response = try server.handleDatagram(&random, address, 0, writer.buffered(), &output);
        var parsed = try dht.bencode.Parser.parse(a, response);
        defer parsed.deinit(a);
        const body = parsed.get("r").?;
        const ipv4 = body.get("nodes").?.bytes;
        const ipv6 = body.get("nodes6").?.bytes;
        try equal(@as(usize, 4 * 26), ipv4.len);
        try equal(@as(usize, 4 * 38), ipv6.len);
        for (0..4) |i| {
            try equal(@as(u8, @intCast(i * 2 + 1)), ipv4[i * 26 + 19]);
            try equal(@as(u8, @intCast(i * 2 + 2)), ipv6[i * 38 + 19]);
            try equal(@as(u16, 6881), std.mem.readInt(u16, ipv4[i * 26 + 24 ..][0..2], .big));
            try equal(@as(u16, 6881), std.mem.readInt(u16, ipv6[i * 38 + 36 ..][0..2], .big));
        }
    }
}

test "tokens survive wrong values and multiple announces until expiry" {
    var tokens = dht.krpc.TokenStore.init(a);
    defer tokens.deinit();
    tokens.ttl_ms = 100;
    var prng = std.Random.DefaultPrng.init(1);
    var random = prng.random();
    const token = try tokens.token(address.ip, 0, &random);
    try expect(!tokens.check(address.ip, "wrong", 1));
    try expect(tokens.check(address.ip, &token, 2));
    try expect(tokens.check(address.ip, &token, 99));
    try expect(!tokens.check(address.ip, &token, 100));
    try equal(@as(usize, 0), tokens.entries.count());
}
test "tokens bound entries and reclaim expired capacity" {
    var tokens = dht.krpc.TokenStore.init(a);
    defer tokens.deinit();
    tokens.max_entries = 1;
    tokens.ttl_ms = 100;
    var prng = std.Random.DefaultPrng.init(2);
    var random = prng.random();
    _ = try tokens.token(address.ip, 0, &random);
    const other: dht.routing.Ip = .{ .v4 = .{ 1, 1, 1, 1 } };
    try std.testing.expectError(error.TokenCapacity, tokens.token(other, 1, &random));
    _ = try tokens.token(other, 100, &random);
    try equal(@as(usize, 1), tokens.entries.count());
}
test "different targets coexist and exact duplicate queries remain suppressed" {
    var manager = dht.TransactionManager.init(a, 16);
    defer manager.deinit();
    const pending: dht.TransactionManager.Pending = .{ .address = address, .query = .get_peers, .target = @splat(1), .created_ms = 0 };
    try manager.register(1, pending);
    var other = pending;
    other.target = @splat(2);
    try manager.register(2, other);
    try std.testing.expectError(error.DuplicateQuery, manager.register(3, pending));
    try std.testing.expectError(error.TransactionInUse, manager.register(2, pending));
    try equal(@as(usize, 2), manager.pending.count());
    _ = manager.take(1, address);
    try manager.register(3, pending);
}
test "cursor wrap skips live transaction identifiers" {
    var manager = dht.TransactionManager.init(a, 3);
    defer manager.deinit();
    try manager.register(1, .{ .address = address, .query = .ping, .target = @splat(0), .created_ms = 0 });
    try equal(@as(u64, 2), manager.next());
    try equal(@as(u64, 0), manager.next());
    try equal(@as(u64, 2), manager.next());
}
test "completed transaction deadlines retire without retries" {
    var manager = dht.TransactionManager.init(a, 16);
    defer manager.deinit();
    try manager.register(1, .{ .address = address, .query = .ping, .target = @splat(0), .created_ms = 0 });
    _ = manager.take(1, address);
    var expired: std.ArrayList(dht.TransactionManager.Pending) = .empty;
    defer expired.deinit(a);
    var retry: std.ArrayList(dht.TransactionManager.Pending) = .empty;
    defer retry.deinit(a);
    try manager.retryOrExpire(15000, 15000, 2, &expired, &retry);
    try equal(@as(usize, 0), manager.deadlines.items.len);
    try equal(@as(usize, 0), retry.items.len);
}
test "empty target bucket falls back to closest known contacts" {
    var table = dht.RoutingTable.init(a, 1, 8);
    defer table.deinit();
    const first: dht.NodeId = @splat(0);
    var second = first;
    second[0] = 0x40;
    var target = first;
    target[0] = 0x80;
    _ = try table.insert(.{ .id = first, .address = address });
    _ = try table.insert(.{ .id = second, .address = .{ .ip = .{ .v4 = .{ 1, 1, 1, 1 } }, .port = 1 } });
    var out: [8]dht.Node = undefined;
    try equal(@as(usize, 2), table.nodesForTarget(target, &out).len);
}
test "public address policy rejects loopback ULA mapped and private IPv4" {
    for ([_][]const u8{ "::1", "::", "fc00::1", "fe80::1", "ff02::1", "::ffff:127.0.0.1" }) |literal| {
        const ip = try std.Io.net.IpAddress.parse(literal, 80);
        try expect(!dht.routing.isRoutable(.{ .ip = .{ .v6 = ip.ip6.bytes }, .port = 80 }));
    }
    try expect(!dht.routing.isRoutable(.{ .ip = .{ .v4 = .{ 127, 0, 0, 1 } }, .port = 80 }));
    try expect(!dht.routing.isRoutable(.{ .ip = address.ip, .port = 0 }));
    try expect(dht.routing.isRoutable(address));
}
test "parser rejects excessive nesting noncanonical integers and duplicate keys" {
    for ([_][]const u8{ "i01e", "i-0e", "i+1e", "i1_0e" }) |input| {
        try std.testing.expectError(error.InvalidInteger, dht.bencode.Parser.parse(a, input));
    }
    try std.testing.expectError(error.InvalidValue, dht.bencode.Parser.parse(a, "01:x"));
    try std.testing.expectError(error.InvalidValue, dht.bencode.Parser.parse(a, "d1:ai1e1:ai2ee"));
    var payload: [256]u8 = undefined;
    @memset(payload[0..128], 'l');
    @memset(payload[128..], 'e');
    try std.testing.expectError(error.NestingTooDeep, dht.bencode.Parser.parse(a, &payload));
}
test "standard node installs both recursive lookup callbacks" {
    var prng = std.Random.DefaultPrng.init(3);
    var node = try dht.StandardDht.init(a, std.testing.io, .{ .bootstrap_nodes = &.{} }, prng.random());
    defer node.deinit();
    try expect(node.server.on_find_node_query != null);
    try expect(node.server.on_get_peers_query != null);
}
test "lookup admission is bounded deduplicated and stopped explicitly" {
    var prng = std.Random.DefaultPrng.init(4);
    var node = try dht.StandardDht.init(a, std.testing.io, .{ .bootstrap_nodes = &.{}, .max_queued_lookups = 1 }, prng.random());
    defer node.deinit();
    try node.getPeers(@splat(1));
    try node.getPeers(@splat(1));
    try std.testing.expectError(error.LookupQueueFull, node.getPeers(@splat(2)));
    node.stop();
    try std.testing.expectError(error.Stopped, node.getPeers(@splat(3)));
}
test "invalid node configuration fails before allocating" {
    var prng = std.Random.DefaultPrng.init(5);
    try std.testing.expectError(error.InvalidConfiguration, dht.StandardDht.init(a, std.testing.io, .{ .k = 0 }, prng.random()));
    try std.testing.expectError(error.InvalidConfiguration, dht.Dht.init(a, std.testing.io, .{ .try_count = 0 }, prng.random()));
}
test "metadata rejects wrong digest and handles multiple pieces out of order" {
    const bytes = try a.alloc(u8, dht.peerwire.block_size + 17);
    defer a.free(bytes);
    @memset(bytes, 0x5a);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &digest, .{});
    var assembler = try dht.peerwire.MetadataAssembler.init(a, digest, bytes.len);
    defer assembler.deinit();
    try assembler.put(1, bytes[dht.peerwire.block_size..]);
    try std.testing.expectError(error.IncompleteMetadata, assembler.finalize());
    try assembler.put(0, bytes[0..dht.peerwire.block_size]);
    const result = try assembler.finalize();
    defer a.free(result);
    try std.testing.expectEqualSlices(u8, bytes, result);
    assembler.metadata[0] ^= 1;
    try std.testing.expectError(error.InfoHashMismatch, assembler.finalize());
}

test "stale deadline cannot retry a reused transaction id" {
    var manager = dht.TransactionManager.init(a, 16);
    defer manager.deinit();
    const pending: dht.TransactionManager.Pending = .{ .address = address, .query = .ping, .target = @splat(0), .created_ms = 0 };
    try manager.register(1, pending);
    _ = manager.take(1, address);
    try manager.register(1, pending);
    var expired: std.ArrayList(dht.TransactionManager.Pending) = .empty;
    defer expired.deinit(a);
    var retry: std.ArrayList(dht.TransactionManager.Pending) = .empty;
    defer retry.deinit(a);
    try manager.retryOrExpire(15000, 15000, 2, &expired, &retry);
    try equal(@as(usize, 1), retry.items.len);
    try equal(@as(u8, 2), retry.items[0].attempts);
    try equal(@as(usize, 1), manager.pending.count());
}

test "parser allocation failures release nested containers" {
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var value = try dht.bencode.Parser.parse(allocator, "d1:ali1ed1:bl3:one3:twoeeee");
            defer value.deinit(allocator);
        }
    }.run, .{});
}

test "routing split allocation failures leave the table usable" {
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var table = dht.RoutingTable.init(allocator, 1, 4);
            defer table.deinit();
            _ = try table.insert(.{ .id = @splat(0), .address = address });
            var second: dht.NodeId = @splat(0);
            second[0] = 0x40;
            const inserted = table.insert(.{ .id = second, .address = .{ .ip = .{ .v4 = .{ 1, 1, 1, 1 } }, .port = 1 } }) catch |err| {
                try expect(table.byAddress(address) != null);
                var out: [4]dht.Node = undefined;
                try equal(@as(usize, 1), table.closest(@splat(0), &out).len);
                return err;
            };
            try expect(inserted);
        }
    }.run, .{});
}

test "transaction register allocation failures do not orphan an index" {
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var manager = dht.TransactionManager.init(allocator, 16);
            defer manager.deinit();
            manager.register(1, .{ .address = address, .query = .ping, .target = @splat(0), .created_ms = 0 }) catch |err| {
                try equal(@as(usize, 0), manager.pending.count());
                try equal(@as(usize, 0), manager.index.count());
                return err;
            };
        }
    }.run, .{});
}

test "blacklist full of expired addresses admits a new address" {
    var blacklist = dht.Blacklist.init(a, 1, 10);
    defer blacklist.deinit();
    try blacklist.insertAddress(address, 0);
    const other: dht.Address = .{ .ip = .{ .v4 = .{ 1, 1, 1, 1 } }, .port = 1 };
    try blacklist.insertAddress(other, 10);
    try expect(blacklist.contains(other, 10));
}

test "malformed response containers cannot add a sender or complete a query" {
    var server = dht.Server.init(a, @splat(0));
    defer server.deinit();
    try server.transactions.register(1, .{ .address = address, .query = .find_node, .target = @splat(3), .created_ms = 0 });
    try std.testing.expectError(error.InvalidMessage, server.handleResponse(address, 1, "d1:rd2:id20:abcdefghijklmnopqrst5:nodes1:xe1:t1:\x011:y1:re"));
    try equal(@as(usize, 0), server.table.nodes.items.len);
    try equal(@as(usize, 1), server.transactions.pending.count());
}

test "IPv6 compact peers use the values list and deliver callbacks" {
    const Context = struct {
        calls: usize = 0,
        fn callback(context: ?*anyopaque, _: dht.NodeId, peer: dht.Peer) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (peer.ip == .v6 and peer.port == 6881) self.calls += 1;
        }
    };
    var context: Context = .{};
    var server = dht.Server.init(a, @splat(0));
    defer server.deinit();
    server.on_get_peers_response = Context.callback;
    server.callback_context = &context;
    try server.transactions.register(1, .{ .address = address, .query = .get_peers, .target = @splat(3), .created_ms = 0 });
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll("d1:rd2:id20:abcdefghijklmnopqrst6:valuesl18:");
    try writer.writeAll(&.{ 0x20, 0x01, 0x48, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x1a, 0xe1 });
    try writer.writeAll("ee1:t1:\x011:y1:re");
    try server.handleResponse(address, 1, writer.buffered());
    try equal(@as(usize, 1), context.calls);
}

test "expired peer sets are removed without leaking their lists" {
    var server = dht.Server.init(a, @splat(0));
    defer server.deinit();
    var peers: std.ArrayList(dht.Peer) = .empty;
    try peers.append(a, address);
    try server.peers.put(@splat(1), peers);
    try server.peer_updated.put(@splat(1), 0);
    server.peer_ttl_ms = 100;
    server.purgePeers(99);
    try equal(@as(usize, 1), server.peers.count());
    server.purgePeers(100);
    try equal(@as(usize, 0), server.peers.count());
    try equal(@as(usize, 0), server.peer_updated.count());
}

test "transaction retry allocation failures preserve the scheduled query" {
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var manager = dht.TransactionManager.init(allocator, 16);
            defer manager.deinit();
            try manager.register(1, .{ .address = address, .query = .ping, .target = @splat(0), .created_ms = 0 });
            var expired: std.ArrayList(dht.TransactionManager.Pending) = .empty;
            defer expired.deinit(allocator);
            var retry: std.ArrayList(dht.TransactionManager.Pending) = .empty;
            defer retry.deinit(allocator);
            manager.retryOrExpire(15000, 15000, 2, &expired, &retry) catch |err| {
                try equal(@as(u8, 1), manager.peek(1, address).?.attempts);
                try equal(@as(usize, 1), manager.deadlines.items.len);
                return err;
            };
        }
    }.run, .{});
}
