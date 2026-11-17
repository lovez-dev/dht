const std = @import("std");
const peerwire = @import("peerwire.zig");
const routing = @import("routing.zig");

fn RingQueue(comptime T: type) type {
    return struct {
        items: std.ArrayList(T) = .empty,
        head: usize = 0,
        len: usize = 0,

        const Self = @This();

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
        }
        fn push(self: *Self, allocator: std.mem.Allocator, capacity: usize, value: T) !void {
            std.debug.assert(self.len < capacity);
            if (self.items.items.len < capacity) {
                try self.items.append(allocator, value);
            } else {
                self.items.items[(self.head + self.len) % capacity] = value;
            }
            self.len += 1;
        }
        fn pop(self: *Self, capacity: usize) ?T {
            if (self.len == 0) return null;
            const result = self.items.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return result;
        }
        fn values(self: *const Self, capacity: usize) QueueValues {
            return .{ .queue = self, .capacity = capacity };
        }
        const QueueValues = struct {
            queue: *const Self,
            capacity: usize,
            index: usize = 0,
            pub fn next(self: *QueueValues) ?T {
                if (self.index == self.queue.len) return null;
                const result = self.queue.items.items[(self.queue.head + self.index) % self.capacity];
                self.index += 1;
                return result;
            }
        };
    };
}

/// Bounded concurrent metadata downloads. Stop and join run and external
/// consumers before deinit; popped response buffers are freed by the caller.
pub const Wire = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    peer_id: [20]u8,
    requests: RingQueue(Request) = .{},
    responses: RingQueue(Response) = .{},
    seen: std.AutoHashMap(Request, i64),
    blacklist: std.AutoHashMap(routing.Address, i64),
    mutex: std.Io.Mutex = .init,
    request_ready: std.Io.Condition = .init,
    request_space: std.Io.Condition = .init,
    response_ready: std.Io.Condition = .init,
    response_space: std.Io.Condition = .init,
    tasks: std.Io.Group = .init,
    permits: std.Io.Semaphore = .{},
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_limit: usize = 32,
    blacklist_capacity: usize = 65_536,
    seen_capacity: usize = 65_536,
    seen_ttl_ms: i64 = std.time.ms_per_hour,
    download_timeout_ms: i64 = 15 * std.time.ms_per_s,
    request_queue_capacity: usize = 1024,
    response_queue_capacity: usize = 1024,
    allow_private_addresses: bool = false,
    active_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    success_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    failure_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    on_metadata: ?*const fn (?*anyopaque, routing.NodeId, []const u8) void = null,
    context: ?*anyopaque = null,

    pub const Request = struct { info_hash: routing.NodeId, peer: routing.Address };
    /// Free metadata with the allocator passed to init after consuming it.
    pub const Response = struct { info_hash: routing.NodeId, peer: routing.Address, metadata: []u8 };
    pub const Config = struct {
        blacklist_capacity: usize = 65_536,
        request_queue_capacity: usize = 1024,
        worker_limit: usize = 32,
        response_queue_capacity: usize = 1024,
        seen_capacity: usize = 65_536,
        seen_ttl_ms: i64 = std.time.ms_per_hour,
        download_timeout_ms: i64 = 15 * std.time.ms_per_s,
        allow_private_addresses: bool = false,
    };
    pub const Stats = struct {
        queued: usize,
        active: usize,
        completed: usize,
        failed: usize,
        blacklisted: usize,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, random: std.Random) Wire {
        return initWithConfig(allocator, io, random, .{});
    }
    pub fn initWithConfig(allocator: std.mem.Allocator, io: std.Io, random: std.Random, config: Config) Wire {
        var wire = Wire{
            .allocator = allocator,
            .io = io,
            .peer_id = undefined,
            .seen = undefined,
            .blacklist = undefined,
            .blacklist_capacity = @max(config.blacklist_capacity, 1),
            .request_queue_capacity = @max(config.request_queue_capacity, 1),
            .response_queue_capacity = @max(config.response_queue_capacity, 1),
            .worker_limit = @max(config.worker_limit, 1),
            .seen_capacity = @max(config.seen_capacity, 1),
            .seen_ttl_ms = config.seen_ttl_ms,
            .download_timeout_ms = config.download_timeout_ms,
            .allow_private_addresses = config.allow_private_addresses,
            .permits = .{ .permits = @max(config.worker_limit, 1) },
        };
        wire.seen = std.AutoHashMap(Request, i64).init(allocator);
        wire.blacklist = std.AutoHashMap(routing.Address, i64).init(allocator);
        var mutable = random;
        mutable.bytes(&wire.peer_id);
        return wire;
    }
    pub fn deinit(self: *Wire) void {
        self.stop();
        self.tasks.cancel(self.io);
        self.requests.deinit(self.allocator);
        var responses = self.responses.values(self.response_queue_capacity);
        while (responses.next()) |response| self.allocator.free(response.metadata);
        self.responses.deinit(self.allocator);
        self.seen.deinit();
        self.blacklist.deinit();
    }
    /// Stops dispatching new jobs and wakes blocked queues. Join run, then deinit
    /// to cancel and join active downloads before releasing storage.
    pub fn stop(self: *Wire) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.request_ready.broadcast(self.io);
        self.request_space.broadcast(self.io);
        self.response_ready.broadcast(self.io);
        self.response_space.broadcast(self.io);
        self.permits.post(self.io);
    }
    /// Waits for request queue space. Duplicate info-hash/endpoint pairs are
    /// discarded while their seen-cache entry remains valid.
    pub fn request(self: *Wire, info_hash: routing.NodeId, peer: routing.Address) !void {
        return self.enqueue(info_hash, peer, true);
    }
    /// Nonblocking admission for callbacks running on a DHT event loop.
    pub fn tryRequest(self: *Wire, info_hash: routing.NodeId, peer: routing.Address) !void {
        return self.enqueue(info_hash, peer, false);
    }
    fn enqueue(self: *Wire, info_hash: routing.NodeId, peer: routing.Address, wait: bool) !void {
        if (self.stopped.load(.acquire)) return error.Stopped;
        if (!routing.isRoutable(peer) and !(self.allow_private_addresses and routing.isUnicast(peer))) return error.InvalidPeer;
        const queued = Request{ .info_hash = info_hash, .peer = peer };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now_ms: i64 = @intCast(std.Io.Timestamp.now(self.io, .awake).toMilliseconds());
        if (self.blacklist.get(peer)) |until| {
            if (until > now_ms) return error.Blacklisted;
            _ = self.blacklist.remove(peer);
        }
        if (self.seen.get(queued)) |expires_ms| {
            if (expires_ms > now_ms) return;
            _ = self.seen.remove(queued);
        }
        while (self.requests.len >= self.request_queue_capacity) {
            if (!wait) return error.QueueFull;
            self.request_space.waitUncancelable(self.io, &self.mutex);
            if (self.stopped.load(.acquire)) return error.Stopped;
        }
        if (self.stopped.load(.acquire)) return error.Stopped;
        try self.evictSeenIfNeeded();
        try self.seen.put(queued, now_ms + self.seen_ttl_ms);
        errdefer _ = self.seen.remove(queued);
        try self.requests.push(self.allocator, self.request_queue_capacity, queued);
        self.request_ready.signal(self.io);
    }
    pub fn nextResponse(self: *Wire) ?Response {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const response = self.responses.pop(self.response_queue_capacity) orelse return null;
        self.response_space.signal(self.io);
        return response;
    }
    /// Waits without cancellation; stop wakes it when the response queue is empty.
    pub fn waitResponse(self: *Wire) ?Response {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.responses.len == 0) {
            if (self.stopped.load(.acquire)) return null;
            self.response_ready.waitUncancelable(self.io, &self.mutex);
        }
        const response = self.responses.pop(self.response_queue_capacity).?;
        self.response_space.signal(self.io);
        return response;
    }
    pub fn waitResponseCancelable(self: *Wire) std.Io.Cancelable!?Response {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        while (self.responses.len == 0) {
            if (self.stopped.load(.acquire)) return null;
            try self.response_ready.wait(self.io, &self.mutex);
        }
        const response = self.responses.pop(self.response_queue_capacity).?;
        self.response_space.signal(self.io);
        return response;
    }
    pub fn stat(self: *Wire) Stats {
        self.mutex.lockUncancelable(self.io);
        const queued = self.requests.len;
        const blacklisted = self.blacklist.count();
        self.mutex.unlock(self.io);
        return .{
            .queued = queued,
            .active = self.active_count.load(.acquire),
            .completed = self.success_count.load(.acquire),
            .failed = self.failure_count.load(.acquire),
            .blacklisted = blacklisted,
        };
    }
    /// Dispatches metadata downloads through the caller's async I/O backend.
    /// No Wire-owned OS worker threads are created.
    pub fn run(self: *Wire) std.Io.Cancelable!void {
        if (self.running.swap(true, .acq_rel)) return;
        defer self.running.store(false, .release);
        while (true) {
            const queued = (try self.waitRequest()) orelse return;
            try self.permits.wait(self.io);
            if (self.stopped.load(.acquire)) {
                self.permits.post(self.io);
                return;
            }
            self.tasks.concurrent(self.io, fetchTaskWithTimeout, .{ self, queued }) catch |err| {
                // A backend may temporarily have no async execution unit.
                // Preserve the request by executing it here instead of
                // leaving a permit consumed and the queue stalled.
                if (err == error.ConcurrencyUnavailable) {
                    try self.fetchTaskWithTimeout(queued);
                    continue;
                }
                self.permits.post(self.io);
                return error.Canceled;
            };
        }
    }
    fn fetchTask(self: *Wire, queued: Request) std.Io.Cancelable!void {
        _ = self.active_count.fetchAdd(1, .acq_rel);
        defer _ = self.active_count.fetchSub(1, .acq_rel);
        self.fetch(queued) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.recordFailure(queued);
            return;
        };
        _ = self.success_count.fetchAdd(1, .acq_rel);
    }
    const Race = union(enum) {
        download: std.Io.Cancelable!void,
        timeout: std.Io.Cancelable!void,
    };
    fn fetchTaskWithTimeout(self: *Wire, queued: Request) std.Io.Cancelable!void {
        // The wrapper owns its permit even if cancellation wins before the
        // download branch starts executing.
        defer self.permits.post(self.io);
        var branches: [2]Race = undefined;
        var select = std.Io.Select(Race).init(self.io, &branches);
        defer select.cancelDiscard();
        // async may execute inline, which would prevent even starting the
        // deadline when a peer stalls. Both branches must have concurrency.
        select.concurrent(.timeout, timeoutTask, .{ self.io, self.download_timeout_ms }) catch {
            self.recordFailure(queued);
            return;
        };
        select.concurrent(.download, fetchTask, .{ self, queued }) catch {
            self.recordFailure(queued);
            return;
        };
        const result = select.await() catch |err| {
            select.cancelDiscard();
            return err;
        };
        select.cancelDiscard();
        switch (result) {
            .download => |download| return download,
            .timeout => |elapsed| {
                // The download task may already have recorded a natural
                // failure before the deadline observes cancellation.
                if (self.failure_count.load(.acquire) == 0) self.recordFailure(queued);
                try elapsed;
                return;
            },
        }
    }
    fn timeoutTask(io: std.Io, timeout_ms: i64) std.Io.Cancelable!void {
        const duration: u64 = @intCast(@max(timeout_ms, 0));
        try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .{ .nanoseconds = duration * std.time.ns_per_ms }, .clock = .awake } }, io);
    }
    fn recordFailure(self: *Wire, queued: Request) void {
        _ = self.failure_count.fetchAdd(1, .acq_rel);
        const now_ms: i64 = @intCast(std.Io.Timestamp.now(self.io, .awake).toMilliseconds());
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.blacklist.count() >= self.blacklist_capacity) {
            var iterator = self.blacklist.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* <= now_ms) _ = self.blacklist.remove(entry.key_ptr.*);
            }
        }
        if (self.blacklist.count() < self.blacklist_capacity or self.blacklist.contains(queued.peer)) {
            self.blacklist.put(queued.peer, now_ms + 60 * std.time.ms_per_min) catch {};
        }
        // A failed endpoint may be retried after its blacklist TTL.
        _ = self.seen.remove(queued);
    }
    fn waitRequest(self: *Wire) std.Io.Cancelable!?Request {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        while (self.requests.len == 0) {
            if (self.stopped.load(.acquire)) return null;
            try self.request_ready.wait(self.io, &self.mutex);
        }
        const job = self.requests.pop(self.request_queue_capacity).?;
        self.request_space.signal(self.io);
        return job;
    }
    fn fetch(self: *Wire, queued: Request) !void {
        const address: std.Io.net.IpAddress = switch (queued.peer.ip) {
            .v4 => |ip| .{ .ip4 = .{ .bytes = ip, .port = queued.peer.port } },
            .v6 => |ip| .{ .ip6 = .{ .bytes = ip, .port = queued.peer.port } },
        };
        const metadata = try peerwire.fetchMetadata(self.allocator, self.io, address, queued.info_hash, self.peer_id);
        errdefer self.allocator.free(metadata);
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (self.responses.len >= self.response_queue_capacity) {
                if (self.stopped.load(.acquire)) return error.Canceled;
                try self.response_space.wait(self.io, &self.mutex);
            }
            if (self.stopped.load(.acquire)) return error.Canceled;
            const queued_metadata = try self.allocator.dupe(u8, metadata);
            errdefer self.allocator.free(queued_metadata);
            try self.responses.push(self.allocator, self.response_queue_capacity, .{ .info_hash = queued.info_hash, .peer = queued.peer, .metadata = queued_metadata });
            self.response_ready.signal(self.io);
        }
        if (self.on_metadata) |callback| callback(self.context, queued.info_hash, metadata);
        self.allocator.free(metadata);
    }
    fn evictSeenIfNeeded(self: *Wire) !void {
        if (self.seen_capacity == 0) return error.InvalidConfiguration;
        if (self.seen.count() < self.seen_capacity) return;
        // This cold path bounds the cache without adding a full-map pass to
        // every incoming peer announcement.
        var iterator = self.seen.iterator();
        if (iterator.next()) |entry| _ = self.seen.remove(entry.key_ptr.*);
    }
};

test "Wire deduplicates queued metadata requests" {
    var prng = std.Random.DefaultPrng.init(1);
    var wire = Wire.init(std.testing.allocator, std.testing.io, prng.random());
    defer wire.deinit();
    const request = routing.Address{ .ip = .{ .v4 = .{ 1, 1, 1, 1 } }, .port = 6881 };
    try wire.request(@as([20]u8, @splat(1)), request);
    try wire.request(@as([20]u8, @splat(1)), request);
    try std.testing.expectEqual(@as(usize, 1), wire.requests.len);
    const stats = wire.stat();
    try std.testing.expectEqual(@as(usize, 1), stats.queued);
    try std.testing.expectEqual(@as(usize, 0), stats.active);
}

test "Wire request queue is FIFO across ring wraparound" {
    var prng = std.Random.DefaultPrng.init(1);
    var wire = Wire.initWithConfig(std.testing.allocator, std.testing.io, prng.random(), .{ .request_queue_capacity = 2 });
    defer wire.deinit();
    const address = routing.Address{ .ip = .{ .v4 = .{ 1, 1, 1, 1 } }, .port = 6881 };
    try wire.request(@as([20]u8, @splat(1)), address);
    try wire.request(@as([20]u8, @splat(2)), address);
    try std.testing.expectEqual(@as(u8, 1), (try wire.waitRequest()).?.info_hash[0]);
    try wire.request(@as([20]u8, @splat(3)), address);
    try std.testing.expectEqual(@as(u8, 2), (try wire.waitRequest()).?.info_hash[0]);
    try std.testing.expectEqual(@as(u8, 3), (try wire.waitRequest()).?.info_hash[0]);
}

test "Wire bounds its seen cache" {
    var prng = std.Random.DefaultPrng.init(1);
    var wire = Wire.initWithConfig(std.testing.allocator, std.testing.io, prng.random(), .{ .seen_capacity = 1, .request_queue_capacity = 4 });
    defer wire.deinit();
    const address = routing.Address{ .ip = .{ .v4 = .{ 1, 1, 1, 1 } }, .port = 6881 };
    try wire.request(@as([20]u8, @splat(1)), address);
    _ = try wire.waitRequest();
    try wire.request(@as([20]u8, @splat(2)), address);
    try std.testing.expectEqual(@as(usize, 1), wire.seen.count());
}

test "Wire retains a configurable per-download deadline" {
    var prng = std.Random.DefaultPrng.init(1);
    var wire = Wire.initWithConfig(std.testing.allocator, std.testing.io, prng.random(), .{ .download_timeout_ms = 123 });
    defer wire.deinit();
    try std.testing.expectEqual(@as(i64, 123), wire.download_timeout_ms);
}

test "Wire blacklist overwrites repeated endpoint failures" {
    var prng = std.Random.DefaultPrng.init(1);
    var wire = Wire.initWithConfig(std.testing.allocator, std.testing.io, prng.random(), .{ .blacklist_capacity = 1 });
    defer wire.deinit();
    const request = Wire.Request{ .info_hash = @as([20]u8, @splat(1)), .peer = .{ .ip = .{ .v4 = .{ 1, 1, 1, 1 } }, .port = 6881 } };
    wire.recordFailure(request);
    wire.recordFailure(request);
    try std.testing.expectEqual(@as(usize, 1), wire.blacklist.count());
}
