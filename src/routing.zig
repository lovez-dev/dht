const std = @import("std");

pub const NodeId = [20]u8;
pub const Ip = union(enum) { v4: [4]u8, v6: [16]u8 };
pub const Address = struct { ip: Ip, port: u16 };
pub const Node = struct { id: NodeId, address: Address, last_active_ms: i64 = 0 };
pub const Peer = Address;
pub const RefreshCandidate = struct { node: Node, target: NodeId };

/// Reject endpoints that cannot be valid public DHT contacts.
pub fn isRoutable(address: Address) bool {
    if (address.port == 0) return false;
    return switch (address.ip) {
        .v4 => |ip| !(ip[0] == 0 or ip[0] == 10 or ip[0] == 127 or ip[0] >= 224 or (ip[0] == 169 and ip[1] == 254) or (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) or (ip[0] == 192 and ip[1] == 168)),
        // Public IPv6 unicast is currently allocated from 2000::/3.
        // This also excludes loopback, ULA, mapped IPv4 and link-local.
        .v6 => |ip| (ip[0] & 0xe0) == 0x20,
    };
}

pub fn isUnicast(address: Address) bool {
    if (address.port == 0) return false;
    return switch (address.ip) {
        .v4 => |ip| ip[0] != 0 and ip[0] < 224,
        .v6 => |ip| ip[0] != 0xff and !std.mem.eql(u8, &ip, &@as([16]u8, @splat(0))),
    };
}

const Bucket = struct {
    prefix: NodeId = @as([20]u8, @splat(0)),
    prefix_len: u8,
    last_changed_ms: i64 = 0,
    probe_pending: bool = false,
    nodes: std.ArrayList(Node) = .empty,
    candidates: std.ArrayList(Node) = .empty,

    fn deinit(self: *Bucket, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.candidates.deinit(allocator);
    }
};

/// A 160-bit K-bucket table. `nodes` is a read-only flattened view retained
/// for callers that need to iterate all known contacts. Iteration order is not
/// stable across removals; mutate contacts through insert/remove only.
pub const RoutingTable = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    buckets: std.ArrayList(Bucket) = .empty,
    addresses: std.AutoHashMap(Address, usize),
    locations: std.AutoHashMap(NodeId, Location),
    allow_private_addresses: bool = false,
    max_nodes: usize,
    k: usize,

    const Location = struct { flat: usize, slot: usize };

    pub fn init(allocator: std.mem.Allocator, k: usize, max_nodes: usize) RoutingTable {
        return .{ .allocator = allocator, .k = k, .max_nodes = max_nodes, .addresses = std.AutoHashMap(Address, usize).init(allocator), .locations = std.AutoHashMap(NodeId, Location).init(allocator) };
    }
    pub fn deinit(self: *RoutingTable) void {
        for (self.buckets.items) |*bucket| bucket.deinit(self.allocator);
        self.buckets.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.addresses.deinit();
        self.locations.deinit();
    }
    pub fn insert(self: *RoutingTable, node: Node) !bool {
        if (!isRoutable(node.address) and !(self.allow_private_addresses and isUnicast(node.address))) return false;
        if (self.buckets.items.len == 0) try self.buckets.append(self.allocator, .{ .prefix_len = 0 });
        // One endpoint must map to one node ID. Do this before taking bucket
        // pointers because removal may compact or split bucket storage.
        if (self.byAddress(node.address)) |other| {
            if (!std.mem.eql(u8, &other.id, &node.id)) _ = self.remove(other.id);
        }
        while (true) {
            const index = self.bucketIndex(node.id);
            const bucket = &self.buckets.items[index];
            if (self.locations.get(node.id)) |location| {
                const old = bucket.nodes.items[location.slot];
                // Reserve/insert the new endpoint before changing either view.
                try self.addresses.put(node.address, location.flat);
                if (!std.meta.eql(old.address, node.address)) _ = self.addresses.remove(old.address);
                bucket.nodes.items[location.slot] = node;
                self.nodes.items[location.flat] = node;
                bucket.last_changed_ms = node.last_active_ms;
                return false;
            }
            // At the global limit, reject new contacts without queuing
            // replacement candidates or starting maintenance traffic.
            if (self.nodes.items.len >= self.max_nodes) return false;
            if (bucket.nodes.items.len < self.k and self.nodes.items.len < self.max_nodes) {
                // No fallible operation follows publication in any view.
                try bucket.nodes.ensureUnusedCapacity(self.allocator, 1);
                try self.nodes.ensureUnusedCapacity(self.allocator, 1);
                try self.addresses.ensureUnusedCapacity(1);
                try self.locations.ensureUnusedCapacity(1);
                self.locations.putAssumeCapacity(node.id, .{ .flat = self.nodes.items.len, .slot = bucket.nodes.items.len });
                bucket.nodes.appendAssumeCapacity(node);
                self.nodes.appendAssumeCapacity(node);
                self.addresses.putAssumeCapacity(node.address, self.nodes.items.len - 1);
                bucket.last_changed_ms = node.last_active_ms;
                return true;
            }
            if (bucket.prefix_len < 160 and bucket.nodes.items.len >= self.k) {
                try self.split(index);
                continue;
            }
            // A fully split bucket keeps recent alternatives for replacement.
            if (findById(bucket.candidates.items, node.id)) |existing| {
                bucket.candidates.items[existing] = node;
            } else {
                if (bucket.candidates.items.len == self.k) _ = bucket.candidates.orderedRemove(0);
                try bucket.candidates.append(self.allocator, node);
            }
            bucket.probe_pending = true;
            return false;
        }
    }
    pub fn remove(self: *RoutingTable, id: NodeId) bool {
        const location = self.locations.get(id) orelse return false;
        const bucket = &self.buckets.items[self.bucketIndex(id)];
        const removed = bucket.nodes.swapRemove(location.slot);
        if (location.slot < bucket.nodes.items.len) {
            self.locations.getPtr(bucket.nodes.items[location.slot].id).?.slot = location.slot;
        }
        _ = self.nodes.swapRemove(location.flat);
        if (location.flat < self.nodes.items.len) {
            const moved = self.nodes.items[location.flat];
            self.locations.getPtr(moved.id).?.flat = location.flat;
            self.addresses.getPtr(moved.address).?.* = location.flat;
        }
        _ = self.locations.remove(id);
        _ = self.addresses.remove(removed.address);
        bucket.last_changed_ms = removed.last_active_ms;
        if (bucket.candidates.items.len > 0 and self.nodes.items.len < self.max_nodes) {
            const replacement = bucket.candidates.items[bucket.candidates.items.len - 1];
            // A failed promotion leaves the candidate queued and all views
            // consistent. The successful removal itself needs no allocation.
            self.addresses.ensureUnusedCapacity(1) catch return true;
            self.locations.ensureUnusedCapacity(1) catch return true;
            _ = bucket.candidates.pop();
            self.locations.putAssumeCapacity(replacement.id, .{ .flat = self.nodes.items.len, .slot = bucket.nodes.items.len });
            bucket.nodes.appendAssumeCapacity(replacement);
            self.nodes.appendAssumeCapacity(replacement);
            self.addresses.putAssumeCapacity(replacement.address, self.nodes.items.len - 1);
        }
        return true;
    }
    pub fn removeByAddress(self: *RoutingTable, address: Address) bool {
        const node = self.byAddress(address) orelse return false;
        return self.remove(node.id);
    }
    pub fn byAddress(self: *const RoutingTable, address: Address) ?Node {
        const index = self.addresses.get(address) orelse return null;
        return self.nodes.items[index];
    }
    pub fn closest(self: *const RoutingTable, target: NodeId, output: []Node) []Node {
        const count: usize = @min(output.len, self.nodes.items.len);
        if (count == 0) return output[0..0];

        // Every ID sharing a target prefix is closer than every ID outside
        // that prefix. Expand its leaf to the smallest ancestor containing
        // enough contacts, then select only within that contiguous leaf range.
        var low = self.bucketIndex(target);
        var high = low + 1;
        var candidates = self.buckets.items[low].nodes.items.len;
        var depth = self.buckets.items[low].prefix_len;
        while (candidates < count and depth > 0) {
            depth -= 1;
            while (low > 0 and hasPrefix(self.buckets.items[low - 1].prefix, target, depth)) {
                low -= 1;
                candidates += self.buckets.items[low].nodes.items.len;
            }
            while (high < self.buckets.items.len and hasPrefix(self.buckets.items[high].prefix, target, depth)) {
                candidates += self.buckets.items[high].nodes.items.len;
                high += 1;
            }
        }
        var filled: usize = 0;
        for (self.buckets.items[low..high]) |bucket| {
            for (bucket.nodes.items) |node| {
                if (filled < count) {
                    output[filled] = node;
                    filled += 1;
                    if (filled == count) heapifyWorst(target, output[0..count]);
                } else if (less(target, node, output[0])) {
                    output[0] = node;
                    siftWorstDown(target, output[0..count], 0);
                }
            }
        }
        std.debug.assert(filled == count);
        std.mem.sort(Node, output[0..count], target, less);
        return output[0..count];
    }
    /// BEP 5 responses contain the closest known contacts across all buckets.
    pub fn nodesForTarget(self: *const RoutingTable, target: NodeId, output: []Node) []Node {
        return self.closest(target, output);
    }
    /// Collects up to `per_bucket` contacts for every expired bucket. The
    /// generated target preserves complete prefix bytes and randomizes the
    /// remainder for this bucket refresh.
    pub fn refreshCandidates(self: *const RoutingTable, now_ms: i64, expired_after_ms: i64, per_bucket: usize, random: *std.Random, output: []RefreshCandidate) usize {
        var count: usize = 0;
        for (self.buckets.items) |bucket| {
            if (bucket.nodes.items.len == 0) continue;
            if (expired_after_ms > 0 and now_ms - bucket.last_changed_ms < expired_after_ms) continue;
            var target: NodeId = undefined;
            random.bytes(&target);
            var prefix_bit: u8 = 0;
            while (prefix_bit < bucket.prefix_len) : (prefix_bit += 1) {
                setBit(&target, prefix_bit, bitAt(bucket.prefix, prefix_bit));
            }
            var emitted: usize = 0;
            for (bucket.nodes.items) |node| {
                if (emitted == per_bucket) break;
                if (count == output.len) return count;
                output[count] = .{ .node = node, .target = target };
                count += 1;
                emitted += 1;
            }
        }
        return count;
    }

    /// Returns stale contacts from buckets that received a replacement
    /// candidate. This is the maintenance trigger used by the Go table's
    /// full-bucket path: probe old contacts before replacements are promoted.
    pub fn takeExpiredProbeCandidates(self: *RoutingTable, now_ms: i64, expired_after_ms: i64, output: []Node) []Node {
        var count: usize = 0;
        for (self.buckets.items) |*bucket| {
            for (bucket.nodes.items) |node| {
                if (now_ms - node.last_active_ms <= expired_after_ms) continue;
                if (count == output.len) return output[0..count];
                output[count] = node;
                count += 1;
            }
            bucket.probe_pending = false;
        }
        return output[0..count];
    }

    fn bucketIndex(self: *const RoutingTable, id: NodeId) usize {
        // Leaf buckets partition the entire ID space and are sorted by their
        // inclusive lower bound. Find the last prefix <= id in O(log buckets).
        var low: usize = 0;
        var high = self.buckets.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (std.mem.order(u8, &self.buckets.items[mid].prefix, &id) != .gt) {
                low = mid + 1;
            } else high = mid;
        }
        return low - 1;
    }
    fn split(self: *RoutingTable, index: usize) !void {
        const original = &self.buckets.items[index];
        const next_len = original.prefix_len + 1;
        var left = Bucket{ .prefix = original.prefix, .prefix_len = next_len, .last_changed_ms = original.last_changed_ms };
        errdefer left.deinit(self.allocator);
        var right = Bucket{ .prefix = original.prefix, .prefix_len = next_len, .last_changed_ms = original.last_changed_ms };
        errdefer right.deinit(self.allocator);
        setBit(&right.prefix, original.prefix_len, true);
        for (original.nodes.items) |node| {
            const destination = if (bitAt(node.id, original.prefix_len)) &right else &left;
            try destination.nodes.append(self.allocator, node);
        }
        for (original.candidates.items) |node| {
            const destination = if (bitAt(node.id, original.prefix_len)) &right else &left;
            try destination.candidates.append(self.allocator, node);
        }
        try self.buckets.ensureUnusedCapacity(self.allocator, 1);
        self.buckets.items[index].deinit(self.allocator);
        self.buckets.items[index] = left;
        self.buckets.insertAssumeCapacity(index + 1, right);
        // Location stores a slot, not a bucket index: sorted bucket insertion
        // does not invalidate locations in other buckets.
        for (self.buckets.items[index .. index + 2]) |bucket| {
            for (bucket.nodes.items, 0..) |node, slot| self.locations.getPtr(node.id).?.slot = slot;
        }
    }
};

fn heapifyWorst(target: NodeId, nodes: []Node) void {
    var index = nodes.len / 2;
    while (index > 0) {
        index -= 1;
        siftWorstDown(target, nodes, index);
    }
}

test "bucket search handles deep splits, boundaries and empty leaves" {
    var table = RoutingTable.init(std.testing.allocator, 1, 256);
    defer table.deinit();
    // Zero, every individual bit, and the highest ID force both deep splits
    // and insertions on either side of existing leaf ranges.
    var ids: [162]NodeId = undefined;
    ids[0] = @splat(0);
    ids[161] = @splat(255);
    for (1..161) |i| {
        ids[i] = @splat(0);
        setBit(&ids[i], @intCast(160 - i), true);
    }
    for (ids, 0..) |id, i| {
        try std.testing.expect(try table.insert(.{ .id = id, .address = .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = @intCast(i + 1) } }));
    }
    for (ids, 0..) |id, i| {
        const bucket = table.buckets.items[table.bucketIndex(id)];
        try std.testing.expect(hasPrefix(bucket.prefix, id, bucket.prefix_len));
        try std.testing.expect(!try table.insert(.{ .id = id, .address = .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = @intCast(i + 1) }, .last_active_ms = 42 }));
    }
    var prng = std.Random.DefaultPrng.init(42);
    for (0..1000) |_| {
        var id: NodeId = undefined;
        prng.random().bytes(&id);
        const bucket = table.buckets.items[table.bucketIndex(id)];
        try std.testing.expect(hasPrefix(bucket.prefix, id, bucket.prefix_len));
    }
    for (ids) |id| try std.testing.expect(table.remove(id));
    for (ids, 0..) |id, i| {
        try std.testing.expect(try table.insert(.{ .id = id, .address = .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = @intCast(i + 1) } }));
    }
    try std.testing.expectEqual(ids.len, table.nodes.items.len);
}
/// A max heap by XOR distance. Its root is the least useful selected node.
fn siftWorstDown(target: NodeId, nodes: []Node, start: usize) void {
    var parent = start;
    while (true) {
        const left = parent * 2 + 1;
        if (left >= nodes.len) return;
        var worst = left;
        const right = left + 1;
        if (right < nodes.len and less(target, nodes[left], nodes[right])) worst = right;
        if (!less(target, nodes[parent], nodes[worst])) return;
        std.mem.swap(Node, &nodes[parent], &nodes[worst]);
        parent = worst;
    }
}

fn findById(nodes: []const Node, id: NodeId) ?usize {
    for (nodes, 0..) |node, index| if (std.mem.eql(u8, &node.id, &id)) return index;
    return null;
}
fn bitAt(id: NodeId, bit: u8) bool {
    return (id[bit / 8] & (@as(u8, 0x80) >> @intCast(bit % 8))) != 0;
}
fn setBit(id: *NodeId, bit: u8, value: bool) void {
    const mask: u8 = @as(u8, 0x80) >> @intCast(bit % 8);
    if (value) id[bit / 8] |= mask else id[bit / 8] &= ~mask;
}
fn hasPrefix(prefix: NodeId, id: NodeId, length: u8) bool {
    const bytes = length / 8;
    if (!std.mem.eql(u8, prefix[0..bytes], id[0..bytes])) return false;
    const remaining: u3 = @intCast(length % 8);
    if (remaining == 0) return true;
    const mask = @as(u8, 0xff) << @as(u3, @intCast(8 - @as(u4, remaining)));
    return (prefix[bytes] & mask) == (id[bytes] & mask);
}
fn less(target: NodeId, left: Node, right: Node) bool {
    for (target, left.id, right.id) |t, a, b| {
        const x = t ^ a;
        const y = t ^ b;
        if (x != y) return x < y;
    }
    return false;
}

test "routing splits full buckets and preserves all nodes" {
    var table = RoutingTable.init(std.testing.allocator, 1, 8);
    defer table.deinit();
    const first = @as([20]u8, @splat(0));
    var second = @as([20]u8, @splat(0));
    second[0] = 0x80;
    try std.testing.expect(try table.insert(.{ .id = first, .address = .{ .ip = .{ .v4 = .{ 1, 1, 1, 1 } }, .port = 1 } }));
    try std.testing.expect(try table.insert(.{ .id = second, .address = .{ .ip = .{ .v4 = .{ 2, 2, 2, 2 } }, .port = 2 } }));
    try std.testing.expect(table.buckets.items.len >= 2);
    try std.testing.expectEqual(@as(usize, 2), table.nodes.items.len);
}

test "routing indexes endpoints and returns nearest nodes in order" {
    var table = RoutingTable.init(std.testing.allocator, 8, 16);
    defer table.deinit();
    var near = @as([20]u8, @splat(0));
    near[19] = 1;
    var far = @as([20]u8, @splat(0));
    far[0] = 0x80;
    const near_address = Address{ .ip = .{ .v4 = .{ 1, 1, 1, 1 } }, .port = 1 };
    const far_address = Address{ .ip = .{ .v4 = .{ 2, 2, 2, 2 } }, .port = 2 };
    _ = try table.insert(.{ .id = far, .address = far_address });
    _ = try table.insert(.{ .id = near, .address = near_address });
    try std.testing.expectEqual(near, table.byAddress(near_address).?.id);
    var result: [2]Node = undefined;
    const closest_nodes = table.closest(@as([20]u8, @splat(0)), &result);
    try std.testing.expectEqual(near, closest_nodes[0].id);
    try std.testing.expect(table.removeByAddress(near_address));
    try std.testing.expect(table.byAddress(near_address) == null);
}

test "routing replaces an endpoint when it advertises a new ID" {
    var table = RoutingTable.init(std.testing.allocator, 8, 16);
    defer table.deinit();
    const address = Address{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = 6881 };
    const first = @as([20]u8, @splat(1));
    const second = @as([20]u8, @splat(2));
    _ = try table.insert(.{ .id = first, .address = address });
    _ = try table.insert(.{ .id = second, .address = address });
    try std.testing.expectEqual(@as(usize, 1), table.nodes.items.len);
    try std.testing.expectEqual(second, table.byAddress(address).?.id);
}

test "routing refresh selects each expired bucket with a bucket target" {
    var table = RoutingTable.init(std.testing.allocator, 1, 8);
    defer table.deinit();
    var other = @as([20]u8, @splat(0));
    other[0] = 0x80;
    _ = try table.insert(.{ .id = @as([20]u8, @splat(0)), .address = .{ .ip = .{ .v4 = .{ 1, 1, 1, 1 } }, .port = 1 }, .last_active_ms = 0 });
    _ = try table.insert(.{ .id = other, .address = .{ .ip = .{ .v4 = .{ 2, 2, 2, 2 } }, .port = 2 }, .last_active_ms = 0 });
    var prng = std.Random.DefaultPrng.init(1);
    var random = prng.random();
    var refreshes: [2]RefreshCandidate = undefined;
    const count = table.refreshCandidates(1, 0, 1, &random, &refreshes);
    try std.testing.expectEqual(@as(usize, 2), count);
    for (refreshes[0..count]) |refresh| {
        for (table.buckets.items) |bucket| {
            if (findById(bucket.nodes.items, refresh.node.id) == null) continue;
            try std.testing.expect(hasPrefix(bucket.prefix, refresh.target, bucket.prefix_len));
            break;
        }
    }
}

test "routing locations agree after churn address changes and endpoint collisions" {
    var table = RoutingTable.init(std.testing.allocator, 4, 256);
    defer table.deinit();
    var prng = std.Random.DefaultPrng.init(0xcafe);
    const random = prng.random();
    var ids: [128]NodeId = undefined;
    for (&ids, 0..) |*id, i| {
        random.bytes(id);
        _ = try table.insert(.{ .id = id.*, .address = .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = @intCast(i + 1) } });
    }
    for (0..1000) |i| {
        const id = ids[random.uintLessThan(usize, ids.len)];
        if (i % 3 == 0) _ = table.remove(id);
        _ = try table.insert(.{ .id = id, .address = .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = random.intRangeAtMost(u16, 1, 192) }, .last_active_ms = @intCast(i) });
        try expectConsistent(&table);
    }
}

fn expectConsistent(table: *const RoutingTable) !void {
    try std.testing.expectEqual(table.nodes.items.len, table.locations.count());
    try std.testing.expectEqual(table.nodes.items.len, table.addresses.count());
    var count: usize = 0;
    for (table.buckets.items, 0..) |bucket, index| {
        for (bucket.nodes.items, 0..) |node, slot| {
            count += 1;
            const location = table.locations.get(node.id).?;
            try std.testing.expectEqual(slot, location.slot);
            try std.testing.expectEqual(index, table.bucketIndex(node.id));
            try std.testing.expect(std.meta.eql(node, table.nodes.items[location.flat]));
            try std.testing.expect(std.meta.eql(node, table.byAddress(node.address).?));
        }
    }
    try std.testing.expectEqual(table.nodes.items.len, count);
}

test "routing allocation failures leave all location and endpoint views consistent" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var table = RoutingTable.init(allocator, 2, 32);
            defer table.deinit();
            errdefer expectConsistent(&table) catch @panic("inconsistent routing table");
            var prng = std.Random.DefaultPrng.init(123);
            var ids: [24]NodeId = undefined;
            for (&ids, 0..) |*id, i| {
                prng.random().bytes(id);
                _ = try table.insert(.{ .id = id.*, .address = .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = @intCast(i + 1) } });
            }
            for (ids, 0..) |id, i| {
                _ = try table.insert(.{ .id = id, .address = .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = @intCast(i + 100) } });
                if (i % 2 == 0) try std.testing.expect(table.remove(id));
            }
            try expectConsistent(&table);
        }
    }.run, .{});
}
