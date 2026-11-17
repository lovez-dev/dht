//! Offline, deterministic bounded stress. No sockets are opened here.
const std = @import("std");
const dht = @import("dht");
const a = std.testing.allocator;

test "stress routing nearest agrees with a full XOR sort" {
    var table = dht.RoutingTable.init(a, 8, 1024);
    defer table.deinit();
    var prng = std.Random.DefaultPrng.init(0x1234);
    const random = prng.random();
    for (0..512) |i| {
        var id: dht.NodeId = undefined;
        random.bytes(&id);
        _ = try table.insert(.{ .id = id, .address = .{ .ip = .{ .v4 = .{ 8, 8, @intCast(i / 256), @truncate(i) } }, .port = 6881 } });
    }
    const all = try a.dupe(dht.Node, table.nodes.items);
    defer a.free(all);
    for (0..128) |_| {
        var target: dht.NodeId = undefined;
        random.bytes(&target);
        std.mem.sort(dht.Node, all, target, struct {
            fn less(t: dht.NodeId, lhs: dht.Node, rhs: dht.Node) bool {
                for (t, lhs.id, rhs.id) |x, y, z| {
                    if (x ^ y != x ^ z) return (x ^ y) < (x ^ z);
                }
                return false;
            }
        }.less);
        var out: [8]dht.Node = undefined;
        const nearest = table.closest(target, &out);
        for (nearest, all[0..nearest.len]) |actual, expected| try std.testing.expectEqual(expected.id, actual.id);
    }
}

test "stress nearest prefix selection matches sorting after sparse and deep bucket churn" {
    for ([_]usize{ 1, 8, std.math.maxInt(usize) }) |k| {
        var table = dht.RoutingTable.init(a, k, 256);
        defer table.deinit();
        var prng = std.Random.DefaultPrng.init(0x55aa);
        const random = prng.random();
        var nodes: [160]dht.Node = undefined;
        for (&nodes, 0..) |*node, i| {
            random.bytes(&node.id);
            // Force deep prefixes as well as broadly distributed contacts.
            if (i % 2 == 0) @memset(node.id[0..18], 0);
            node.address = .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = @intCast(i + 1) };
            node.last_active_ms = 0;
            _ = try table.insert(node.*);
        }
        for (0..4) |phase| {
            if (phase == 1) for (nodes, 0..) |node, i| {
                if (i % 3 == 0) _ = table.remove(node.id);
            };
            if (phase == 2) for (nodes) |node| {
                _ = table.remove(node.id);
            };
            if (phase == 3) for (nodes, 0..) |node, i| {
                if (i % 4 == 0) _ = try table.insert(node);
            };
            const all = try a.dupe(dht.Node, table.nodes.items);
            defer a.free(all);
            for (0..48) |i| {
                var target: dht.NodeId = undefined;
                random.bytes(&target);
                if (i % 3 == 0) target = nodes[i].id;
                if (i % 3 == 1) @memset(target[0..18], 0);
                std.mem.sort(dht.Node, all, target, struct {
                    fn less(t: dht.NodeId, lhs: dht.Node, rhs: dht.Node) bool {
                        for (t, lhs.id, rhs.id) |x, y, z| {
                            if (x ^ y != x ^ z) return (x ^ y) < (x ^ z);
                        }
                        return false;
                    }
                }.less);
                var out: [192]dht.Node = undefined;
                for ([_]usize{ 0, 1, 7, 8, 63, 160, 192 }) |limit| {
                    const nearest = table.closest(target, out[0..limit]);
                    try std.testing.expectEqual(@min(limit, all.len), nearest.len);
                    for (nearest, all[0..nearest.len]) |actual, expected| try std.testing.expectEqual(expected.id, actual.id);
                }
            }
        }
    }
}

test "stress transaction churn retires indexes and stale deadlines" {
    var manager = dht.TransactionManager.init(a, 1 << 24);
    defer manager.deinit();
    var expired: std.ArrayList(dht.TransactionManager.Pending) = .empty;
    defer expired.deinit(a);
    var retry: std.ArrayList(dht.TransactionManager.Pending) = .empty;
    defer retry.deinit(a);
    const address: dht.Address = .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = 1 };
    for (0..20) |round| {
        for (0..1000) |i| {
            var target: dht.NodeId = @splat(0);
            std.mem.writeInt(u32, target[0..4], @intCast(i), .big);
            const id = manager.next();
            try manager.register(id, .{ .address = address, .query = .get_peers, .target = target, .created_ms = @intCast(round * 30000) });
            if (i % 2 == 0) _ = manager.take(id, address);
        }
        try manager.retryOrExpire(@intCast(round * 30000 + 15000), 15000, 1, &expired, &retry);
        try std.testing.expectEqual(@as(usize, 500), expired.items.len);
        try std.testing.expectEqual(@as(usize, 0), manager.pending.count());
        try std.testing.expectEqual(@as(usize, 0), manager.index.count());
        try std.testing.expectEqual(@as(usize, 0), manager.deadlines.items.len);
        expired.clearRetainingCapacity();
    }
}

test "stress malformed bencode is bounded and releases every allocation" {
    var prng = std.Random.DefaultPrng.init(0xabc);
    const random = prng.random();
    var bytes: [256]u8 = undefined;
    for (0..10000) |_| {
        random.bytes(&bytes);
        const len = random.intRangeAtMost(usize, 0, bytes.len);
        var value = dht.bencode.Parser.parse(a, bytes[0..len]) catch continue;
        value.deinit(a);
    }
}
