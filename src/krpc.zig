const std = @import("std");
const bencode = @import("bencode.zig");
const routing = @import("routing.zig");
const transactions = @import("transaction.zig");
const Blacklist = @import("blacklist.zig").Blacklist;

pub const Error = error{ InvalidMessage, InvalidId, InvalidQuery, InvalidToken };
pub const Query = enum { ping, find_node, get_peers, announce_peer };

pub const TokenStore = struct {
    entries: std.AutoHashMap(routing.Ip, Entry),
    allocator: std.mem.Allocator,
    ttl_ms: i64 = 10 * std.time.ms_per_min,
    max_entries: usize = 65536,
    pub const Entry = struct { token: [5]u8, created_ms: i64 };
    pub fn init(allocator: std.mem.Allocator) TokenStore {
        return .{ .allocator = allocator, .entries = std.AutoHashMap(routing.Ip, Entry).init(allocator) };
    }
    pub fn deinit(self: *TokenStore) void {
        self.entries.deinit();
    }
    pub fn token(self: *TokenStore, ip: routing.Ip, now_ms: i64, random: *std.Random) ![5]u8 {
        if (self.entries.get(ip)) |entry| if (now_ms - entry.created_ms < self.ttl_ms) return entry.token;
        var generated: [5]u8 = undefined;
        random.bytes(&generated);
        if (!self.entries.contains(ip) and self.entries.count() >= self.max_entries) {
            self.purge(now_ms);
            if (self.entries.count() >= self.max_entries) return error.TokenCapacity;
        }
        try self.entries.put(ip, .{ .token = generated, .created_ms = now_ms });
        return generated;
    }
    pub fn check(self: *TokenStore, ip: routing.Ip, supplied_token: []const u8, now_ms: i64) bool {
        const entry = self.entries.get(ip) orelse return false;
        if (now_ms - entry.created_ms >= self.ttl_ms) {
            _ = self.entries.remove(ip);
            return false;
        }
        // BEP 5 tokens remain reusable until expiry, including behind NAT.
        return std.mem.eql(u8, &entry.token, supplied_token);
    }
    pub fn purge(self: *TokenStore, now_ms: i64) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (now_ms - entry.value_ptr.created_ms >= self.ttl_ms) _ = self.entries.remove(entry.key_ptr.*);
        }
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    id: routing.NodeId,
    table: routing.RoutingTable,
    tokens: TokenStore,
    peers: std.AutoHashMap(routing.NodeId, std.ArrayList(routing.Peer)),
    transactions: transactions.Manager,
    blacklist: Blacklist,
    peer_updated: std.AutoHashMap(routing.NodeId, i64),
    peer_ttl_ms: i64 = 30 * std.time.ms_per_min,
    max_peer_hashes: usize = 4096,
    mode: enum { standard, crawl } = .standard,
    k: usize = 8,
    on_announce_peer: ?*const fn (?*anyopaque, routing.NodeId, routing.Address) void = null,
    on_get_peers: ?*const fn (?*anyopaque, routing.NodeId, routing.Address) void = null,
    on_get_peers_response: ?*const fn (?*anyopaque, routing.NodeId, routing.Peer) void = null,
    on_get_peers_query: ?*const fn (?*anyopaque, routing.Address, routing.NodeId) void = null,
    on_find_node_query: ?*const fn (?*anyopaque, routing.Address, routing.NodeId) void = null,
    lookup_context: ?*anyopaque = null,
    callback_context: ?*anyopaque = null,
    // Mutable protocol state is owned by one DHT event loop. Observers read
    // this atomic snapshot instead of touching maps while that loop mutates.
    stat_nodes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    stat_pending_queries: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    stat_blacklisted: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(allocator: std.mem.Allocator, id: routing.NodeId) Server {
        return .{ .allocator = allocator, .id = id, .table = routing.RoutingTable.init(allocator, 8, 5000), .tokens = TokenStore.init(allocator), .peer_updated = std.AutoHashMap(routing.NodeId, i64).init(allocator), .peers = std.AutoHashMap(routing.NodeId, std.ArrayList(routing.Peer)).init(allocator), .transactions = transactions.Manager.init(allocator, std.math.maxInt(u32)), .blacklist = Blacklist.init(allocator, 65536, std.time.ms_per_hour) };
    }
    pub fn deinit(self: *Server) void {
        self.table.deinit();
        self.tokens.deinit();
        var it = self.peers.valueIterator();
        while (it.next()) |peers| peers.deinit(self.allocator);
        self.peers.deinit();
        self.peer_updated.deinit();
        self.transactions.deinit();
        self.blacklist.deinit();
    }

    pub const Stats = struct { nodes: usize, pending_queries: usize, blacklisted: usize };
    /// Publishes a state snapshot from the owning event loop.
    pub fn refreshStats(self: *Server) void {
        self.stat_nodes.store(self.table.nodes.items.len, .release);
        self.stat_pending_queries.store(self.transactions.pending.count(), .release);
        self.stat_blacklisted.store(self.blacklist.entries.count(), .release);
    }
    /// Safe to call from monitoring code while the owner loop is running.
    pub fn stats(self: *const Server) Stats {
        return .{
            .nodes = self.stat_nodes.load(.acquire),
            .pending_queries = self.stat_pending_queries.load(.acquire),
            .blacklisted = self.stat_blacklisted.load(.acquire),
        };
    }

    /// Crawl mode advertises an ID near the requested target. This is the
    /// deliberate BEP-5 deviation encourages peers to continue their lookup
    /// through this node and eventually announce themselves.
    pub fn responseIdFor(self: *const Server, target: ?routing.NodeId) routing.NodeId {
        if (self.mode == .crawl) if (target) |value| {
            var id = value;
            @memcpy(id[15..], self.id[15..]);
            return id;
        };
        return self.id;
    }

    pub fn queryIdFor(self: *const Server, target: routing.NodeId) routing.NodeId {
        return self.responseIdFor(target);
    }

    /// Parses one UDP KRPC request and writes the corresponding KRPC response.
    pub fn handleDatagram(self: *Server, random: *std.Random, source: routing.Address, now_ms: i64, input: []const u8, output: []u8) ![]const u8 {
        var parsed = try bencode.Parser.parse(self.allocator, input);
        defer parsed.deinit(self.allocator);
        return self.handleParsedDatagram(random, source, now_ms, &parsed, output);
    }
    /// Handles a validated bencode tree owned by the caller. This lets the
    /// UDP runtime classify and process a packet with one parse.
    pub fn handleParsedDatagram(self: *Server, random: *std.Random, source: routing.Address, now_ms: i64, parsed: *const bencode.Value, output: []u8) ![]const u8 {
        if (parsed.* != .dict) return error.InvalidMessage;
        const transaction = parsed.get("t") orelse return error.InvalidMessage;
        const kind = parsed.get("y") orelse return error.InvalidMessage;
        if (transaction.* != .bytes or kind.* != .bytes or !std.mem.eql(u8, kind.bytes, "q")) return error.InvalidMessage;
        const query = parsed.get("q") orelse return error.InvalidMessage;
        const args = parsed.get("a") orelse return error.InvalidMessage;
        if (query.* != .bytes or args.* != .dict) return error.InvalidMessage;
        const sender = args.get("id") orelse return error.InvalidId;
        if (sender.* != .bytes or sender.bytes.len != 20) return error.InvalidId;
        var sender_id: routing.NodeId = undefined;
        @memcpy(&sender_id, sender.bytes);
        if (!std.mem.eql(u8, &sender_id, &self.id)) {
            if (self.table.byAddress(source)) |known| if (!std.mem.eql(u8, &known.id, &sender_id)) {
                try self.blacklist.insertAddress(source, now_ms);
                _ = self.table.removeByAddress(source);
                return error.InvalidId;
            };
            _ = try self.table.insert(.{ .id = sender_id, .address = source, .last_active_ms = now_ms });
        }
        if (std.mem.eql(u8, query.bytes, "find_node") and self.mode == .crawl) return output[0..0];
        var writer = std.Io.Writer.fixed(output);
        try writer.writeAll("d1:rd");
        if (std.mem.eql(u8, query.bytes, "get_peers")) {
            const info_hash = args.get("info_hash") orelse return error.InvalidQuery;
            if (info_hash.* != .bytes or info_hash.bytes.len != 20) return error.InvalidQuery;
            var requested_hash: routing.NodeId = undefined;
            @memcpy(&requested_hash, info_hash.bytes);
            if (self.on_get_peers) |callback| callback(self.callback_context, requested_hash, source);
            var closest_nodes: [8]routing.Node = undefined;
            var target: routing.NodeId = undefined;
            @memcpy(&target, info_hash.bytes);
            try responseId(&writer, self.responseIdFor(target));
            if (self.mode == .crawl) {
                const token = try self.tokens.token(source.ip, now_ms, random);
                try bencode.encodeString(&writer, "nodes");
                try bencode.encodeString(&writer, "");
                try bencode.encodeString(&writer, "token");
                try bencode.encodeString(&writer, &token);
            } else if (self.peers.get(target)) |peers| {
                const token = try self.tokens.token(source.ip, now_ms, random);
                try bencode.encodeString(&writer, "token");
                try bencode.encodeString(&writer, &token);
                try bencode.encodeString(&writer, "values");
                try writer.writeByte('l');
                for (peers.items) |peer| {
                    switch (peer.ip) {
                        .v4 => |ip| {
                            var compact: [6]u8 = undefined;
                            @memcpy(compact[0..4], &ip);
                            std.mem.writeInt(u16, compact[4..6], peer.port, .big);
                            try bencode.encodeString(&writer, &compact);
                        },
                        .v6 => |ip| {
                            var compact: [18]u8 = undefined;
                            @memcpy(compact[0..16], &ip);
                            std.mem.writeInt(u16, compact[16..18], peer.port, .big);
                            try bencode.encodeString(&writer, &compact);
                        },
                    }
                }
                try writer.writeByte('e');
            } else {
                const nearest = self.table.closest(target, &closest_nodes);
                try writeCompactNodes(&writer, nearest);
                try writeCompactNodes6(&writer, nearest);
                const token = try self.tokens.token(source.ip, now_ms, random);
                try bencode.encodeString(&writer, "token");
                try bencode.encodeString(&writer, &token);
            }
        } else if (std.mem.eql(u8, query.bytes, "find_node")) {
            const target_value = args.get("target") orelse return error.InvalidQuery;
            if (target_value.* != .bytes or target_value.bytes.len != 20) return error.InvalidQuery;
            var closest_nodes: [8]routing.Node = undefined;
            var target: routing.NodeId = undefined;
            @memcpy(&target, target_value.bytes);
            try responseId(&writer, self.responseIdFor(target));
            const nearest = self.table.nodesForTarget(target, &closest_nodes);
            try writeCompactNodes(&writer, nearest);
            try writeCompactNodes6(&writer, nearest);
        } else if (std.mem.eql(u8, query.bytes, "announce_peer")) {
            const token = args.get("token") orelse return error.InvalidToken;
            if (token.* != .bytes or !self.tokens.check(source.ip, token.bytes, now_ms)) return error.InvalidToken;
            const info_hash = args.get("info_hash") orelse return error.InvalidQuery;
            const announced_port = args.get("port") orelse return error.InvalidQuery;
            if (info_hash.* != .bytes or info_hash.bytes.len != 20 or announced_port.* != .integer or announced_port.integer < 0 or announced_port.integer > std.math.maxInt(u16)) return error.InvalidQuery;
            var target: routing.NodeId = undefined;
            @memcpy(&target, info_hash.bytes);
            const implied = if (args.get("implied_port")) |value| value.* == .integer and value.integer != 0 else false;
            const peer = routing.Address{ .ip = source.ip, .port = if (implied) source.port else @intCast(announced_port.integer) };
            if (!self.acceptsAddress(peer)) return error.InvalidQuery;
            if (self.mode == .standard) try self.storePeer(target, peer, now_ms);
            if (self.on_announce_peer) |callback| callback(self.callback_context, target, peer);
            try responseId(&writer, self.responseIdFor(null));
        } else if (std.mem.eql(u8, query.bytes, "ping")) {
            try responseId(&writer, self.responseIdFor(null));
        } else return error.InvalidQuery;
        try writer.writeAll("e1:t");
        try bencode.encodeString(&writer, transaction.bytes);
        try writer.writeAll("1:y1:re");
        return writer.buffered();
    }

    pub fn purgePeers(self: *Server, now_ms: i64) void {
        var iterator = self.peer_updated.iterator();
        while (iterator.next()) |entry| {
            if (now_ms - entry.value_ptr.* < self.peer_ttl_ms) continue;
            const hash = entry.key_ptr.*;
            if (self.peers.fetchRemove(hash)) |removed| {
                var list = removed.value;
                list.deinit(self.allocator);
            }
            _ = self.peer_updated.remove(hash);
        }
    }
    fn storePeer(self: *Server, info_hash: routing.NodeId, peer: routing.Peer, now_ms: i64) !void {
        if (!self.peers.contains(info_hash) and self.peers.count() >= self.max_peer_hashes) {
            self.purgePeers(now_ms);
            if (self.peers.count() >= self.max_peer_hashes) return error.PeerCapacity;
        }
        try self.peer_updated.put(info_hash, now_ms);
        const entry = try self.peers.getOrPut(info_hash);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        for (entry.value_ptr.items) |*old| if (std.meta.eql(old.*, peer)) {
            old.* = peer;
            return;
        };
        const limit = @min(self.k, 64);
        if (limit == 0) return error.InvalidConfiguration;
        if (entry.value_ptr.items.len >= limit) _ = entry.value_ptr.orderedRemove(0);
        try entry.value_ptr.append(self.allocator, peer);
    }

    /// Absorbs a KRPC response to one of this node's outbound queries.
    pub fn handleResponse(self: *Server, source: routing.Address, now_ms: i64, input: []const u8) !void {
        var parsed = try bencode.Parser.parse(self.allocator, input);
        defer parsed.deinit(self.allocator);
        return self.handleParsedResponse(source, now_ms, &parsed);
    }
    /// Handles a parsed response tree owned by the caller.
    pub fn handleParsedResponse(self: *Server, source: routing.Address, now_ms: i64, parsed: *const bencode.Value) !void {
        if (parsed.* != .dict) return error.InvalidMessage;
        const kind = parsed.get("y") orelse return error.InvalidMessage;
        const transaction_id = parsed.get("t") orelse return error.InvalidMessage;
        const response = parsed.get("r") orelse return error.InvalidMessage;
        if (kind.* != .bytes or !std.mem.eql(u8, kind.bytes, "r") or response.* != .dict or transaction_id.* != .bytes or transaction_id.bytes.len == 0 or transaction_id.bytes.len > 4) return error.InvalidMessage;
        if (response.get("nodes")) |value| if (value.* != .bytes or value.bytes.len % 26 != 0) return error.InvalidMessage;
        if (response.get("nodes6")) |value| if (value.* != .bytes or value.bytes.len % 38 != 0) return error.InvalidMessage;
        if (response.get("values")) |value| if (value.* != .list) return error.InvalidMessage;
        if (response.get("values6")) |value| if (value.* != .list) return error.InvalidMessage;
        const cursor = std.mem.readVarInt(u32, transaction_id.bytes, .big);
        const pending = self.transactions.peek(cursor, source);
        if (pending == null) return error.UnknownTransaction;
        const sender = response.get("id") orelse return error.InvalidId;
        if (sender.* != .bytes or sender.bytes.len != 20) return error.InvalidId;
        var sender_id: routing.NodeId = undefined;
        @memcpy(&sender_id, sender.bytes);
        if (std.mem.eql(u8, &sender_id, &self.id)) {
            _ = self.transactions.take(cursor, source);
            return;
        }
        if (!std.mem.eql(u8, &sender_id, &self.id)) {
            if (self.table.byAddress(source)) |known| if (!std.mem.eql(u8, &known.id, &sender_id)) {
                try self.blacklist.insertAddress(source, now_ms);
                _ = self.table.removeByAddress(source);
                return error.InvalidId;
            };
            _ = try self.table.insert(.{ .id = sender_id, .address = source, .last_active_ms = now_ms });
        }
        if (response.get("nodes")) |nodes| {
            if (nodes.* != .bytes or nodes.bytes.len % 26 != 0) return error.InvalidMessage;
            var index: usize = 0;
            var discovered = false;
            var found_target = false;
            while (index < nodes.bytes.len) : (index += 26) {
                const compact = nodes.bytes[index..][0..26];
                var node_id: routing.NodeId = undefined;
                @memcpy(&node_id, compact[0..20]);
                if (pending) |query| found_target = found_target or std.mem.eql(u8, &node_id, &query.target);
                const address = routing.Address{ .ip = .{ .v4 = compact[20..24].* }, .port = std.mem.readInt(u16, compact[24..26], .big) };
                if (!std.mem.eql(u8, &node_id, &self.id) and self.acceptsAddress(address) and !self.blacklist.contains(address, now_ms)) discovered = (try self.table.insert(.{ .id = node_id, .address = address, .last_active_ms = now_ms })) or discovered;
            }
            if (pending) |query| if (discovered and query.query == .get_peers and response.get("values") == null and response.get("values6") == null) {
                var nearest: [64]routing.Node = undefined;
                for (self.table.closest(query.target, &nearest)) |node| {
                    if (self.on_get_peers_query) |callback| callback(self.lookup_context, node.address, query.target);
                }
            };
            if (pending) |query| if (discovered and !found_target and query.query == .find_node) {
                var nearest: [8]routing.Node = undefined;
                for (self.table.closest(query.target, &nearest)) |node| {
                    if (self.on_find_node_query) |callback| callback(self.lookup_context, node.address, query.target);
                }
            };
        }
        if (response.get("nodes6")) |nodes6| {
            if (nodes6.* != .bytes or nodes6.bytes.len % 38 != 0) return error.InvalidMessage;
            var index: usize = 0;
            var discovered = false;
            var found_target = false;
            while (index < nodes6.bytes.len) : (index += 38) {
                const compact = nodes6.bytes[index..][0..38];
                var node_id: routing.NodeId = undefined;
                @memcpy(&node_id, compact[0..20]);
                if (pending) |query| found_target = found_target or std.mem.eql(u8, &node_id, &query.target);
                const address = routing.Address{ .ip = .{ .v6 = compact[20..36].* }, .port = std.mem.readInt(u16, compact[36..38], .big) };
                if (!std.mem.eql(u8, &node_id, &self.id) and self.acceptsAddress(address) and !self.blacklist.contains(address, now_ms)) discovered = (try self.table.insert(.{ .id = node_id, .address = address, .last_active_ms = now_ms })) or discovered;
            }
            if (pending) |query| if (discovered and query.query == .get_peers and response.get("values") == null and response.get("values6") == null) {
                var nearest: [64]routing.Node = undefined;
                for (self.table.closest(query.target, &nearest)) |node| {
                    if (self.on_get_peers_query) |callback| callback(self.lookup_context, node.address, query.target);
                }
            };
            if (pending) |query| if (discovered and !found_target and query.query == .find_node) {
                var nearest: [8]routing.Node = undefined;
                for (self.table.closest(query.target, &nearest)) |node| {
                    if (self.on_find_node_query) |callback| callback(self.lookup_context, node.address, query.target);
                }
            };
        }
        if (response.get("values")) |values| {
            if (values.* != .list) return error.InvalidMessage;
            for (values.list.items) |item| {
                if (item != .bytes) continue;
                const peer: routing.Peer = switch (item.bytes.len) {
                    6 => .{ .ip = .{ .v4 = item.bytes[0..4].* }, .port = std.mem.readInt(u16, item.bytes[4..6], .big) },
                    18 => .{ .ip = .{ .v6 = item.bytes[0..16].* }, .port = std.mem.readInt(u16, item.bytes[16..18], .big) },
                    else => continue,
                };
                if (self.acceptsAddress(peer)) if (pending) |query| if (query.query == .get_peers) if (self.on_get_peers_response) |callback| callback(self.callback_context, query.target, peer);
            }
        }
        if (response.get("values6")) |values6| {
            if (values6.* != .list) return error.InvalidMessage;
            for (values6.list.items) |item| {
                if (item != .bytes or item.bytes.len != 18) continue;
                const peer = routing.Peer{ .ip = .{ .v6 = item.bytes[0..16].* }, .port = std.mem.readInt(u16, item.bytes[16..18], .big) };
                if (self.acceptsAddress(peer)) if (pending) |query| if (query.query == .get_peers) if (self.on_get_peers_response) |callback| callback(self.callback_context, query.target, peer);
            }
        }
        if (pending) |_| _ = self.transactions.take(cursor, source);
    }

    fn acceptsAddress(self: *const Server, address: routing.Address) bool {
        return routing.isRoutable(address) or (self.table.allow_private_addresses and routing.isUnicast(address));
    }

    pub fn handleParsedError(self: *Server, source: routing.Address, parsed: *const bencode.Value) !void {
        if (parsed.* != .dict) return error.InvalidMessage;
        const transaction_id = parsed.get("t") orelse return error.InvalidMessage;
        const error_value = parsed.get("e") orelse return error.InvalidMessage;
        if (transaction_id.* != .bytes or error_value.* != .list or transaction_id.bytes.len == 0 or transaction_id.bytes.len > 4) return error.InvalidMessage;
        _ = self.transactions.take(std.mem.readVarInt(u32, transaction_id.bytes, .big), source);
    }
};

fn responseId(writer: anytype, id: routing.NodeId) !void {
    try bencode.encodeString(writer, "id");
    try bencode.encodeString(writer, &id);
}
fn writeCompactNodes(writer: anytype, nodes: []const routing.Node) !void {
    var compact: [8 * 26]u8 = undefined;
    var count: usize = 0;
    for (nodes) |node| {
        const ip = switch (node.address.ip) {
            .v4 => |value| value,
            .v6 => continue,
        };
        const index = count;
        count += 1;
        const offset = index * 26;
        @memcpy(compact[offset..][0..20], &node.id);
        @memcpy(compact[offset + 20 ..][0..4], &ip);
        std.mem.writeInt(u16, compact[offset + 24 ..][0..2], node.address.port, .big);
    }
    try bencode.encodeString(writer, "nodes");
    try bencode.encodeString(writer, compact[0 .. count * 26]);
}
fn writeCompactNodes6(writer: anytype, nodes: []const routing.Node) !void {
    var compact: [8 * 38]u8 = undefined;
    var count: usize = 0;
    for (nodes) |node| {
        const ip = switch (node.address.ip) {
            .v4 => continue,
            .v6 => |value| value,
        };
        const offset = count * 38;
        count += 1;
        @memcpy(compact[offset..][0..20], &node.id);
        @memcpy(compact[offset + 20 ..][0..16], &ip);
        std.mem.writeInt(u16, compact[offset + 36 ..][0..2], node.address.port, .big);
    }
    if (count == 0) return;
    try bencode.encodeString(writer, "nodes6");
    try bencode.encodeString(writer, compact[0 .. count * 38]);
}

test "KRPC answers a ping and adds its sender" {
    var server = Server.init(std.testing.allocator, @as([20]u8, @splat('s')));
    defer server.deinit();
    var prng = std.Random.DefaultPrng.init(1);
    var random = prng.random();
    var output: [512]u8 = undefined;
    const result = try server.handleDatagram(&random, .{ .ip = .{ .v4 = .{ 1, 2, 3, 4 } }, .port = 6881 }, 0, "d1:ad2:id20:abcdefghijklmnopqrste1:q4:ping1:t2:aa1:y1:qe", &output);
    try std.testing.expect(std.mem.indexOf(u8, result, "1:y1:r") != null);
    try std.testing.expectEqual(@as(usize, 1), server.table.nodes.items.len);
}

test "KRPC rejects nested malformed requests without corrupting parsed ownership" {
    var server = Server.init(std.testing.allocator, @as([20]u8, @splat('s')));
    defer server.deinit();
    var prng = std.Random.DefaultPrng.init(1);
    var random = prng.random();
    var output: [512]u8 = undefined;
    try std.testing.expectError(
        error.InvalidId,
        server.handleDatagram(&random, .{ .ip = .{ .v4 = .{ 1, 2, 3, 4 } }, .port = 6881 }, 0, "d1:ade1:q4:ping1:t2:aa1:y1:qe", &output),
    );
}

test "KRPC ignores responses from a different endpoint" {
    var server = Server.init(std.testing.allocator, @as([20]u8, @splat('s')));
    defer server.deinit();
    const destination = routing.Address{ .ip = .{ .v4 = .{ 1, 2, 3, 4 } }, .port = 6881 };
    try server.transactions.register(1, .{ .address = destination, .query = .ping, .target = @as([20]u8, @splat(0)), .created_ms = 0 });
    try std.testing.expect(server.transactions.take(1, .{ .ip = .{ .v4 = .{ 9, 9, 9, 9 } }, .port = 6881 }) == null);
    try std.testing.expectEqual(@as(usize, 1), server.transactions.pending.count());
}

test "crawl get_peers returns an empty node list and a target-near ID" {
    var server = Server.init(std.testing.allocator, @as([20]u8, @splat(0xaa)));
    defer server.deinit();
    server.mode = .crawl;
    var random_state = std.Random.DefaultPrng.init(1);
    var random = random_state.random();
    const target = @as([20]u8, @splat(0x11));
    var request: [256]u8 = undefined;
    var request_writer = std.Io.Writer.fixed(&request);
    try request_writer.writeAll("d1:ad2:id20:");
    try request_writer.writeAll(&(@as([20]u8, @splat(0x22))));
    try request_writer.writeAll("9:info_hash20:");
    try request_writer.writeAll(&target);
    try request_writer.writeAll("e1:q9:get_peers1:t2:aa1:y1:qe");
    var response: [512]u8 = undefined;
    const encoded = try server.handleDatagram(&random, .{ .ip = .{ .v4 = .{ 1, 2, 3, 4 } }, .port = 6881 }, 0, request_writer.buffered(), &response);
    var parsed = try bencode.Parser.parse(std.testing.allocator, encoded);
    defer parsed.deinit(std.testing.allocator);
    const body = parsed.get("r").?;
    try std.testing.expectEqualStrings("", body.get("nodes").?.bytes);
    try std.testing.expectEqualSlices(u8, target[0..15], body.get("id").?.bytes[0..15]);
}

test "get_peers invokes its callback" {
    const Context = struct {
        var calls: usize = 0;
        var hash: routing.NodeId = undefined;
        var peer: routing.Address = undefined;
        fn callback(_: ?*anyopaque, info_hash: routing.NodeId, source: routing.Address) void {
            calls += 1;
            hash = info_hash;
            peer = source;
        }
    };
    Context.calls = 0;
    var server = Server.init(std.testing.allocator, @as([20]u8, @splat(0)));
    defer server.deinit();
    server.on_get_peers = Context.callback;
    var random_state = std.Random.DefaultPrng.init(1);
    var random = random_state.random();
    const target = @as([20]u8, @splat(0x44));
    var request: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&request);
    try writer.writeAll("d1:ad2:id20:");
    try writer.writeAll(&(@as([20]u8, @splat(0x22))));
    try writer.writeAll("9:info_hash20:");
    try writer.writeAll(&target);
    try writer.writeAll("e1:q9:get_peers1:t2:aa1:y1:qe");
    var response: [512]u8 = undefined;
    _ = try server.handleDatagram(&random, .{ .ip = .{ .v4 = .{ 1, 2, 3, 4 } }, .port = 6881 }, 0, writer.buffered(), &response);
    try std.testing.expectEqual(@as(usize, 1), Context.calls);
    try std.testing.expectEqualSlices(u8, &target, &Context.hash);
    try std.testing.expectEqual(@as(u16, 6881), Context.peer.port);
}

test "get_peers response recursively queries closest discovered nodes" {
    const Context = struct {
        var calls: usize = 0;
        var found_discovered: bool = false;
        var target: routing.NodeId = undefined;
        fn callback(_: ?*anyopaque, address: routing.Address, info_hash: routing.NodeId) void {
            calls += 1;
            if (std.meta.eql(address, routing.Address{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = 6881 })) found_discovered = true;
            target = info_hash;
        }
    };
    Context.calls = 0;
    Context.found_discovered = false;
    var server = Server.init(std.testing.allocator, @as([20]u8, @splat(0)));
    defer server.deinit();
    server.on_get_peers_query = Context.callback;
    const source = routing.Address{ .ip = .{ .v4 = .{ 1, 2, 3, 4 } }, .port = 6881 };
    const target = @as([20]u8, @splat(0x44));
    try server.transactions.register(1, .{ .address = source, .query = .get_peers, .target = target, .created_ms = 0 });
    var compact: [26]u8 = undefined;
    @memset(compact[0..20], 0x55);
    compact[20..24].* = .{ 8, 8, 8, 8 };
    std.mem.writeInt(u16, compact[24..26], 6881, .big);
    var response: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&response);
    try writer.writeAll("d1:rd2:id20:");
    try writer.writeAll(&(@as([20]u8, @splat(0x11))));
    try bencode.encodeString(&writer, "nodes");
    try bencode.encodeString(&writer, &compact);
    try writer.writeAll("e1:t4:");
    var transaction: [4]u8 = undefined;
    std.mem.writeInt(u32, &transaction, 1, .big);
    try writer.writeAll(&transaction);
    try writer.writeAll("1:y1:re");
    try server.handleResponse(source, 1, writer.buffered());
    try std.testing.expect(Context.calls > 0);
    try std.testing.expect(Context.found_discovered);
    try std.testing.expectEqualSlices(u8, &target, &Context.target);
}

test "find_node response recursively queries closest discovered nodes" {
    const Context = struct {
        var calls: usize = 0;
        fn callback(_: ?*anyopaque, _: routing.Address, _: routing.NodeId) void {
            calls += 1;
        }
    };
    Context.calls = 0;
    var server = Server.init(std.testing.allocator, @as([20]u8, @splat(0)));
    defer server.deinit();
    server.on_find_node_query = Context.callback;
    const source = routing.Address{ .ip = .{ .v4 = .{ 1, 2, 3, 4 } }, .port = 6881 };
    const target = @as([20]u8, @splat(0x44));
    try server.transactions.register(1, .{ .address = source, .query = .find_node, .target = target, .created_ms = 0 });
    var compact: [26]u8 = undefined;
    @memset(compact[0..20], 0x55);
    compact[20..24].* = .{ 8, 8, 8, 8 };
    std.mem.writeInt(u16, compact[24..26], 6881, .big);
    var response: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&response);
    try writer.writeAll("d1:rd2:id20:");
    try writer.writeAll(&(@as([20]u8, @splat(0x11))));
    try bencode.encodeString(&writer, "nodes");
    try bencode.encodeString(&writer, &compact);
    try writer.writeAll("e1:t4:");
    var transaction: [4]u8 = undefined;
    std.mem.writeInt(u32, &transaction, 1, .big);
    try writer.writeAll(&transaction);
    try writer.writeAll("1:y1:re");
    try server.handleResponse(source, 1, writer.buffered());
    try std.testing.expect(Context.calls > 0);
}
