const std = @import("std");
const routing = @import("routing.zig");

pub const Manager = struct {
    allocator: std.mem.Allocator,
    cursor: u64 = 0,
    max_cursor: u64,
    pending: std.AutoHashMap(u64, Pending),
    index: std.AutoHashMap(IndexKey, u64),
    deadlines: std.ArrayList(Deadline) = .empty,
    timeout_ms: i64 = 15 * std.time.ms_per_s,
    generation: u64 = 0,
    const IndexKey = struct { address: routing.Address, query: Query, target: routing.NodeId };
    pub const Pending = struct {
        address: routing.Address,
        query: Query,
        target: routing.NodeId,
        created_ms: i64,
        attempts: u8 = 1,
        deadline_ms: i64 = 0,
        version: u64 = 0,
        payload: [128]u8 = undefined,
        payload_len: usize = 0,
    };
    const Deadline = struct { at_ms: i64, id: u64, version: u64 };
    pub const Query = enum { ping, find_node, get_peers, announce_peer };
    pub fn init(allocator: std.mem.Allocator, max_cursor: u64) Manager {
        return .{
            .allocator = allocator,
            .max_cursor = max_cursor,
            .pending = std.AutoHashMap(u64, Pending).init(allocator),
            .index = std.AutoHashMap(IndexKey, u64).init(allocator),
        };
    }
    pub fn deinit(self: *Manager) void {
        self.pending.deinit();
        self.index.deinit();
        self.deadlines.deinit(self.allocator);
    }
    pub fn next(self: *Manager) u64 {
        std.debug.assert(self.max_cursor > 0);
        while (true) {
            self.cursor = (self.cursor +% 1) % self.max_cursor;
            if (!self.pending.contains(self.cursor)) break;
            // A full ID space is a programming error; production uses 32 bits.
            std.debug.assert(self.pending.count() < self.max_cursor);
        }
        return self.cursor;
    }
    pub fn register(self: *Manager, id: u64, pending: Pending) !void {
        if (self.pending.contains(id)) return error.TransactionInUse;
        if (pending.payload_len > pending.payload.len) return error.InvalidPayload;
        const key = IndexKey{ .address = pending.address, .query = pending.query, .target = pending.target };
        if (self.index.contains(key)) return error.DuplicateQuery;
        var scheduled = pending;
        scheduled.deadline_ms = pending.created_ms + self.timeout_ms;
        self.generation +%= 1;
        scheduled.version = self.generation;
        try self.pending.put(id, scheduled);
        errdefer _ = self.pending.remove(id);
        try self.index.put(key, id);
        errdefer _ = self.index.remove(key);
        try self.pushDeadline(.{ .at_ms = scheduled.deadline_ms, .id = id, .version = scheduled.version });
    }
    pub fn take(self: *Manager, id: u64, source: routing.Address) ?Pending {
        const item = self.pending.get(id) orelse return null;
        if (!std.meta.eql(item.address, source)) return null;
        const removed = self.pending.fetchRemove(id).?.value;
        _ = self.index.remove(.{ .address = removed.address, .query = removed.query, .target = removed.target });
        return removed;
    }
    pub fn peek(self: *const Manager, id: u64, source: routing.Address) ?Pending {
        const item = self.pending.get(id) orelse return null;
        if (!std.meta.eql(item.address, source)) return null;
        return item;
    }
    pub fn expire(self: *Manager, now_ms: i64, timeout_ms: i64, expired: *std.ArrayList(Pending)) !void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (now_ms - entry.value_ptr.created_ms >= timeout_ms) {
                try expired.append(self.allocator, entry.value_ptr.*);
                _ = self.index.remove(.{ .address = entry.value_ptr.address, .query = entry.value_ptr.query, .target = entry.value_ptr.target });
                _ = self.pending.remove(entry.key_ptr.*);
            }
        }
    }
    pub fn retryOrExpire(self: *Manager, now_ms: i64, timeout_ms: i64, max_attempts: u8, expired: *std.ArrayList(Pending), retry: *std.ArrayList(Pending)) !void {
        std.debug.assert(timeout_ms == self.timeout_ms);
        while (self.deadlines.items.len > 0 and self.deadlines.items[0].at_ms <= now_ms) {
            const event = self.deadlines.items[0];
            const pending = self.pending.getPtr(event.id) orelse {
                _ = self.popDeadline();
                continue;
            };
            if (pending.version != event.version or pending.deadline_ms != event.at_ms) {
                _ = self.popDeadline();
                continue;
            }
            if (pending.attempts < max_attempts) {
                try retry.ensureUnusedCapacity(self.allocator, 1);
            } else {
                try expired.ensureUnusedCapacity(self.allocator, 1);
            }
            _ = self.popDeadline();
            if (pending.attempts < max_attempts) {
                pending.attempts += 1;
                pending.created_ms = now_ms;
                pending.deadline_ms = now_ms + timeout_ms;
                self.generation +%= 1;
                pending.version = self.generation;
                retry.appendAssumeCapacity(pending.*);
                try self.pushDeadline(.{ .at_ms = pending.deadline_ms, .id = event.id, .version = pending.version });
            } else {
                const removed = self.pending.fetchRemove(event.id).?.value;
                expired.appendAssumeCapacity(removed);
                _ = self.index.remove(.{ .address = removed.address, .query = removed.query, .target = removed.target });
            }
        }
    }
    fn pushDeadline(self: *Manager, event: Deadline) !void {
        try self.deadlines.append(self.allocator, event);
        var child = self.deadlines.items.len - 1;
        while (child > 0) {
            const parent = (child - 1) / 2;
            if (!deadlineLess(self.deadlines.items[child], self.deadlines.items[parent])) break;
            std.mem.swap(Deadline, &self.deadlines.items[child], &self.deadlines.items[parent]);
            child = parent;
        }
    }
    fn popDeadline(self: *Manager) ?Deadline {
        if (self.deadlines.items.len == 0) return null;
        const result = self.deadlines.items[0];
        const last = self.deadlines.pop().?;
        if (self.deadlines.items.len > 0) {
            self.deadlines.items[0] = last;
            var parent: usize = 0;
            while (true) {
                const left = parent * 2 + 1;
                if (left >= self.deadlines.items.len) break;
                var child = left;
                const right = left + 1;
                if (right < self.deadlines.items.len and deadlineLess(self.deadlines.items[right], self.deadlines.items[left])) child = right;
                if (!deadlineLess(self.deadlines.items[child], self.deadlines.items[parent])) break;
                std.mem.swap(Deadline, &self.deadlines.items[parent], &self.deadlines.items[child]);
                parent = child;
            }
        }
        return result;
    }
};

fn deadlineLess(left: Manager.Deadline, right: Manager.Deadline) bool {
    return left.at_ms < right.at_ms or (left.at_ms == right.at_ms and left.id < right.id);
}

test "transaction manager binds responses to their source" {
    var manager = Manager.init(std.testing.allocator, 100);
    defer manager.deinit();
    const address = routing.Address{ .ip = .{ .v4 = .{ 1, 1, 1, 1 } }, .port = 1 };
    const id = manager.next();
    try manager.register(id, .{ .address = address, .query = .ping, .target = @as([20]u8, @splat(0)), .created_ms = 0 });
    try std.testing.expect(manager.take(id, .{ .ip = .{ .v4 = .{ 2, 2, 2, 2 } }, .port = 1 }) == null);
    try std.testing.expect(manager.take(id, address) != null);
}

test "transaction manager returns expired queries" {
    var manager = Manager.init(std.testing.allocator, 100);
    defer manager.deinit();
    const address = routing.Address{ .ip = .{ .v4 = .{ 2, 2, 2, 2 } }, .port = 2 };
    try manager.register(manager.next(), .{ .address = address, .query = .find_node, .target = @as([20]u8, @splat(0)), .created_ms = 0 });
    var expired: std.ArrayList(Manager.Pending) = .empty;
    defer expired.deinit(std.testing.allocator);
    try manager.expire(15, 10, &expired);
    try std.testing.expectEqual(@as(usize, 1), expired.items.len);
    try std.testing.expect(std.meta.eql(address, expired.items[0].address));
}

test "transaction manager schedules retries by deadline" {
    var manager = Manager.init(std.testing.allocator, 100);
    defer manager.deinit();
    const address = routing.Address{ .ip = .{ .v4 = .{ 3, 3, 3, 3 } }, .port = 3 };
    try manager.register(manager.next(), .{ .address = address, .query = .ping, .target = @as([20]u8, @splat(0)), .created_ms = 0 });
    var expired: std.ArrayList(Manager.Pending) = .empty;
    defer expired.deinit(std.testing.allocator);
    var retry: std.ArrayList(Manager.Pending) = .empty;
    defer retry.deinit(std.testing.allocator);
    try manager.retryOrExpire(15 * std.time.ms_per_s, 15 * std.time.ms_per_s, 2, &expired, &retry);
    try std.testing.expectEqual(@as(usize, 1), retry.items.len);
    try std.testing.expectEqual(@as(u8, 2), retry.items[0].attempts);
    retry.clearRetainingCapacity();
    try manager.retryOrExpire(30 * std.time.ms_per_s, 15 * std.time.ms_per_s, 2, &expired, &retry);
    try std.testing.expectEqual(@as(usize, 1), expired.items.len);
}

test "transaction manager suppresses duplicate endpoint queries until completion" {
    var manager = Manager.init(std.testing.allocator, 100);
    defer manager.deinit();
    const address = routing.Address{ .ip = .{ .v4 = .{ 4, 4, 4, 4 } }, .port = 4 };
    const pending = Manager.Pending{ .address = address, .query = .find_node, .target = @as([20]u8, @splat(0)), .created_ms = 0 };
    try manager.register(1, pending);
    try std.testing.expectError(error.DuplicateQuery, manager.register(2, pending));
    _ = manager.take(1, address).?;
    try manager.register(2, pending);
}
