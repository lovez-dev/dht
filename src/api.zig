const std = @import("std");
const bencode = @import("bencode.zig");
const routing = @import("routing.zig");
const krpc = @import("krpc.zig");
const runtime = @import("runtime.zig");

pub const CrawlConfig = struct {
    port: u16 = 6881,
    network: runtime.UdpService.Network = .udp4,
    k: usize = 8,
    k_bucket_size: usize = std.math.maxInt(usize),
    max_nodes: usize = 5000,
    try_count: u8 = 2,
    refresh_node_num: usize = 256,
    blacklist_capacity: usize = 65_536,
    blocked_ips: []const routing.Ip = &.{},
    node_expired_after_ms: i64 = 0,
    bucket_expired_after_ms: i64 = 0,
    check_bucket_period_ms: i64 = 5 * std.time.ms_per_s,
    token_expired_after_ms: i64 = 10 * std.time.ms_per_min,
    bootstrap_nodes: []const routing.Address = &default_bootstrap_nodes,
    on_get_peers_response: ?*const fn (?*anyopaque, routing.NodeId, routing.Peer) void = null,
    on_announce_peer: ?*const fn (?*anyopaque, routing.NodeId, routing.Address) void = null,
    on_get_peers: ?*const fn (?*anyopaque, routing.NodeId, routing.Address) void = null,
    context: ?*anyopaque = null,
    allow_private_addresses: bool = false,
    max_pending_queries: usize = 4096,
    max_queued_lookups: usize = 256,
};

pub const StandardConfig = struct {
    port: u16 = 6881,
    network: runtime.UdpService.Network = .udp4,
    k: usize = 8,
    k_bucket_size: usize = 8,
    max_nodes: usize = 5000,
    try_count: u8 = 2,
    refresh_node_num: usize = 8,
    blacklist_capacity: usize = 65_536,
    blocked_ips: []const routing.Ip = &.{},
    node_expired_after_ms: i64 = 15 * std.time.ms_per_min,
    bucket_expired_after_ms: i64 = 15 * std.time.ms_per_min,
    check_bucket_period_ms: i64 = 30 * std.time.ms_per_s,
    token_expired_after_ms: i64 = 10 * std.time.ms_per_min,
    bootstrap_nodes: []const routing.Address = &default_bootstrap_nodes,
    on_announce_peer: ?*const fn (?*anyopaque, routing.NodeId, routing.Address) void = null,
    on_get_peers: ?*const fn (?*anyopaque, routing.NodeId, routing.Address) void = null,
    on_get_peers_response: ?*const fn (?*anyopaque, routing.NodeId, routing.Peer) void = null,
    context: ?*anyopaque = null,
    allow_private_addresses: bool = false,
    max_pending_queries: usize = 4096,
    max_queued_lookups: usize = 256,
};

pub const default_bootstrap_nodes = [_]routing.Address{
    .{ .ip = .{ .v4 = .{ 67, 215, 246, 10 } }, .port = 6881 }, // router.bittorrent.com
    .{ .ip = .{ .v4 = .{ 82, 221, 103, 244 } }, .port = 6881 }, // router.utorrent.com
    .{ .ip = .{ .v4 = .{ 87, 98, 162, 88 } }, .port = 6881 }, // dht.transmissionbt.com
};

const transactions = @import("transaction.zig");
pub const Mode = enum { crawl, standard };
pub const Dht = Node(.crawl);
pub const StandardDht = Node(.standard);

/// One task runs the UDP event loop. Only getPeers, start, pause, stop and
/// stat may be called from other threads. Join run before deinit.
fn Node(comptime mode: Mode) type {
    return struct {
        const Self = @This();
        pub const Config = if (mode == .crawl) CrawlConfig else StandardConfig;
        allocator: std.mem.Allocator,
        io: std.Io,
        server: krpc.Server,
        config: Config,
        random: std.Random,
        service: ?*runtime.UdpService = null,
        running: std.atomic.Value(bool) = .init(true),
        stopped: std.atomic.Value(bool) = .init(false),
        received_packets: std.atomic.Value(usize) = .init(0),
        dropped_packets: std.atomic.Value(usize) = .init(0),
        sent_packets: std.atomic.Value(usize) = .init(0),
        lookup_mutex: std.Io.Mutex = .init,
        queued_lookups: std.ArrayList(routing.NodeId) = .empty,
        last_refresh_ms: ?i64 = null,
        last_bootstrap_ms: ?i64 = null,
        last_purge_ms: ?i64 = null,

        pub const Stats = struct {
            running: bool,
            nodes: usize,
            pending_queries: usize,
            blacklisted: usize,
            received_packets: usize,
            dropped_packets: usize,
            sent_packets: usize,
        };

        pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config, random: std.Random) !Self {
            if (config.k == 0 or config.k_bucket_size == 0 or config.max_nodes == 0 or
                config.try_count == 0 or config.max_pending_queries == 0 or
                config.max_queued_lookups == 0 or config.token_expired_after_ms <= 0 or
                config.check_bucket_period_ms <= 0 or config.node_expired_after_ms < 0 or
                config.bucket_expired_after_ms < 0) return error.InvalidConfiguration;
            var id: routing.NodeId = undefined;
            random.bytes(&id);
            var server = krpc.Server.init(allocator, id);
            errdefer server.deinit();
            server.mode = if (mode == .crawl) .crawl else .standard;
            server.k = config.k;
            server.table.k = config.k_bucket_size;
            server.table.max_nodes = config.max_nodes;
            server.table.allow_private_addresses = config.allow_private_addresses;
            server.blacklist.max_entries = config.blacklist_capacity;
            server.tokens.ttl_ms = config.token_expired_after_ms;
            const now_ms = now(io);
            for (config.blocked_ips) |ip| try server.blacklist.insertIp(ip, now_ms);
            server.on_announce_peer = config.on_announce_peer;
            server.on_get_peers = config.on_get_peers;
            server.on_get_peers_response = config.on_get_peers_response;
            server.on_find_node_query = onFindNodeQuery;
            server.on_get_peers_query = onGetPeersQuery;
            server.callback_context = config.context;
            server.refreshStats();
            return .{ .allocator = allocator, .io = io, .server = server, .config = config, .random = random };
        }
        pub fn deinit(self: *Self) void {
            self.queued_lookups.deinit(self.allocator);
            self.server.deinit();
        }
        pub fn start(self: *Self) void {
            self.running.store(true, .release);
        }
        pub fn pause(self: *Self) void {
            self.running.store(false, .release);
        }
        pub fn stop(self: *Self) void {
            self.stopped.store(true, .release);
        }
        pub fn stat(self: *const Self) Stats {
            const snapshot = self.server.stats();
            return .{
                .running = self.running.load(.acquire) and !self.stopped.load(.acquire),
                .nodes = snapshot.nodes,
                .pending_queries = snapshot.pending_queries,
                .blacklisted = snapshot.blacklisted,
                .received_packets = self.received_packets.load(.acquire),
                .dropped_packets = self.dropped_packets.load(.acquire),
                .sent_packets = self.sent_packets.load(.acquire),
            };
        }
        /// Thread-safe, bounded admission. Actual sends run on the event loop.
        /// Lookups may be queued before run; they wait until contacts are known.
        pub fn getPeers(self: *Self, info_hash: routing.NodeId) !void {
            self.lookup_mutex.lockUncancelable(self.io);
            defer self.lookup_mutex.unlock(self.io);
            if (self.stopped.load(.acquire)) return error.Stopped;
            for (self.queued_lookups.items) |queued| if (std.mem.eql(u8, &queued, &info_hash)) return;
            if (self.queued_lookups.items.len >= self.config.max_queued_lookups) return error.LookupQueueFull;
            try self.queued_lookups.append(self.allocator, info_hash);
        }
        pub fn bootstrap(self: *Self, service: *runtime.UdpService) !void {
            defer self.server.refreshStats();
            for (self.config.bootstrap_nodes) |address| {
                self.findNode(service, address, self.server.id) catch |err| switch (err) {
                    error.OutOfMemory, error.Canceled => return err,
                    else => continue,
                };
            }
        }
        pub fn findNode(self: *Self, service: *runtime.UdpService, destination: routing.Address, target: routing.NodeId) !void {
            try self.sendQuery(service, destination, .find_node, target);
        }
        fn sendQuery(self: *Self, service: *runtime.UdpService, destination: routing.Address, query: transactions.Manager.Query, target: routing.NodeId) !void {
            if (self.server.transactions.pending.count() >= self.config.max_pending_queries) return error.QueryCapacity;
            var packet: [128]u8 = undefined;
            var writer = std.Io.Writer.fixed(&packet);
            const transaction = self.server.transactions.next();
            try writer.writeAll("d1:ad2:id20:");
            const query_id = if (query == .ping) self.server.id else self.server.queryIdFor(target);
            try writer.writeAll(&query_id);
            switch (query) {
                .find_node => try writer.writeAll("6:target20:"),
                .get_peers => try writer.writeAll("9:info_hash20:"),
                .ping => {},
                .announce_peer => unreachable,
            }
            if (query != .ping) try writer.writeAll(&target);
            try writer.writeAll("e1:q");
            try bencode.encodeString(&writer, @tagName(query));
            try writer.writeAll("1:t");
            var transaction_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &transaction_bytes, @intCast(transaction), .big);
            try bencode.encodeString(&writer, &transaction_bytes);
            try writer.writeAll("1:y1:qe");
            const payload = writer.buffered();
            var pending = transactions.Manager.Pending{ .address = destination, .query = query, .target = target, .created_ms = now(service.io) };
            @memcpy(pending.payload[0..payload.len], payload);
            pending.payload_len = payload.len;
            try self.server.transactions.register(transaction, pending);
            errdefer _ = self.server.transactions.take(transaction, destination);
            try service.send(destination, payload);
            _ = self.sent_packets.fetchAdd(1, .acq_rel);
        }
        fn sendGetPeers(self: *Self, service: *runtime.UdpService, target: routing.NodeId) !void {
            var candidates: [64]routing.Node = undefined;
            const limit = @min(candidates.len, self.config.max_pending_queries);
            for (self.server.table.closest(target, candidates[0..limit])) |node| {
                if (std.mem.eql(u8, &node.id, &self.server.id)) continue;
                self.sendQuery(service, node.address, .get_peers, target) catch |err| switch (err) {
                    error.OutOfMemory, error.Canceled => return err,
                    else => continue,
                };
            }
        }
        /// Shared maintenance for crawler and standard mode; also usable by
        /// deterministic embedders that drive the socket themselves.
        pub fn maintain(self: *Self, service: *runtime.UdpService, now_ms: i64) !void {
            defer self.server.refreshStats();
            var expired: std.ArrayList(transactions.Manager.Pending) = .empty;
            defer expired.deinit(self.allocator);
            var retry: std.ArrayList(transactions.Manager.Pending) = .empty;
            defer retry.deinit(self.allocator);
            try self.server.transactions.retryOrExpire(now_ms, self.server.transactions.timeout_ms, self.config.try_count, &expired, &retry);
            for (retry.items) |pending| {
                service.send(pending.address, pending.payload[0..pending.payload_len]) catch |err| {
                    if (err == error.Canceled) return err;
                    continue;
                };
                _ = self.sent_packets.fetchAdd(1, .acq_rel);
            }
            for (expired.items) |pending| {
                try self.server.blacklist.insertAddress(pending.address, now_ms);
                _ = self.server.table.removeByAddress(pending.address);
            }
            if (self.last_purge_ms == null or now_ms - self.last_purge_ms.? >= std.time.ms_per_min) {
                self.last_purge_ms = now_ms;
                self.server.tokens.purge(now_ms);
                self.server.purgePeers(now_ms);
                self.server.blacklist.purge(now_ms);
            }
            if (self.server.table.nodes.items.len == 0) {
                if (self.last_bootstrap_ms == null or now_ms - self.last_bootstrap_ms.? >= 15 * std.time.ms_per_s) {
                    self.last_bootstrap_ms = now_ms;
                    try self.bootstrap(service);
                }
            } else {
                // Reserve enough transaction room before consuming admission.
                // Backpressure retains queued hashes instead of dropping them.
                const needed = @min(@as(usize, 64), self.server.table.nodes.items.len, self.config.max_pending_queries);
                while (self.server.transactions.pending.count() + needed <= self.config.max_pending_queries) {
                    self.lookup_mutex.lockUncancelable(self.io);
                    const target = if (self.queued_lookups.items.len > 0) self.queued_lookups.orderedRemove(0) else null;
                    self.lookup_mutex.unlock(self.io);
                    try self.sendGetPeers(service, target orelse break);
                }
            }
            if ((self.last_refresh_ms == null or now_ms - self.last_refresh_ms.? >= self.config.check_bucket_period_ms) and self.server.transactions.pending.count() == 0) {
                self.last_refresh_ms = now_ms;
                var candidates: [256]routing.RefreshCandidate = undefined;
                const count = self.server.table.refreshCandidates(now_ms, self.config.bucket_expired_after_ms, self.config.refresh_node_num, &self.random, &candidates);
                for (candidates[0..count]) |candidate| {
                    self.findNode(service, candidate.node.address, candidate.target) catch |err| {
                        if (err == error.Canceled or err == error.OutOfMemory) return err;
                        continue;
                    };
                    if (mode == .crawl) _ = self.server.table.remove(candidate.node.id);
                }
            }
            if (mode == .standard) {
                var probes: [64]routing.Node = undefined;
                for (self.server.table.takeExpiredProbeCandidates(now_ms, self.config.node_expired_after_ms, &probes)) |node| {
                    self.sendQuery(service, node.address, .ping, @splat(0)) catch |err| {
                        if (err == error.Canceled or err == error.OutOfMemory) return err;
                    };
                }
            }
        }
        pub fn run(self: *Self, io: std.Io) !void {
            var service = try runtime.UdpService.bind(io, &self.server, &self.random, self.config.port, self.config.network);
            defer service.deinit();
            service.allow_private_addresses = self.config.allow_private_addresses;
            self.service = &service;
            defer self.service = null;
            self.server.lookup_context = self;
            defer self.server.lookup_context = null;
            while (!self.stopped.load(.acquire)) {
                if (!self.running.load(.acquire)) {
                    try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .{ .nanoseconds = 50 * std.time.ns_per_ms }, .clock = .awake } }, io);
                    continue;
                }
                try self.maintain(&service, now(io));
                const handled = service.handleOnce(.{ .duration = .{ .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms }, .clock = .awake } }) catch |err| {
                    if (err == error.Canceled) return err;
                    _ = self.dropped_packets.fetchAdd(1, .acq_rel);
                    continue;
                };
                if (handled) _ = self.received_packets.fetchAdd(1, .acq_rel);
                self.server.refreshStats();
            }
        }
        fn onFindNodeQuery(context: ?*anyopaque, destination: routing.Address, target: routing.NodeId) void {
            const self: *Self = @ptrCast(@alignCast(context orelse return));
            self.findNode(self.service orelse return, destination, target) catch {};
        }
        fn onGetPeersQuery(context: ?*anyopaque, destination: routing.Address, target: routing.NodeId) void {
            const self: *Self = @ptrCast(@alignCast(context orelse return));
            self.sendQuery(self.service orelse return, destination, .get_peers, target) catch {};
        }
    };
}
fn now(io: std.Io) i64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).toMilliseconds());
}

test "Dht pause and start update its stat snapshot" {
    var random_state = std.Random.DefaultPrng.init(1);
    var node = try Dht.init(std.testing.allocator, std.testing.io, .{ .bootstrap_nodes = &.{} }, random_state.random());
    defer node.deinit();
    node.pause();
    try std.testing.expect(!node.stat().running);
    node.start();
    try std.testing.expect(node.stat().running);
    node.stop();
    try std.testing.expect(!node.stat().running);
}
