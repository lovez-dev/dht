const std = @import("std");
const Address = @import("routing.zig").Address;

/// Bounded, expiring blacklist for invalid or unreachable DHT contacts.
pub const Blacklist = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(Key, i64),
    max_entries: usize,
    ttl_ms: i64,
    pub const Key = union(enum) { ip: @import("routing.zig").Ip, address: Address };

    pub fn init(allocator: std.mem.Allocator, max_entries: usize, ttl_ms: i64) Blacklist {
        return .{ .allocator = allocator, .entries = std.AutoHashMap(Key, i64).init(allocator), .max_entries = max_entries, .ttl_ms = ttl_ms };
    }
    pub fn deinit(self: *Blacklist) void {
        self.entries.deinit();
    }
    pub fn insertIp(self: *Blacklist, ip: @import("routing.zig").Ip, now_ms: i64) !void {
        _ = now_ms;
        const key = Key{ .ip = ip };
        if (self.entries.count() < self.max_entries or self.entries.contains(key)) try self.entries.put(key, -1);
    }
    pub fn insertAddress(self: *Blacklist, address: Address, now_ms: i64) !void {
        try self.insert(.{ .address = address }, now_ms);
    }
    pub fn contains(self: *Blacklist, address: Address, now_ms: i64) bool {
        return self.active(.{ .ip = address.ip }, now_ms) or self.active(.{ .address = address }, now_ms);
    }
    pub fn purge(self: *Blacklist, now_ms: i64) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* >= 0 and now_ms - entry.value_ptr.* >= self.ttl_ms) _ = self.entries.remove(entry.key_ptr.*);
        }
    }
    fn insert(self: *Blacklist, key: Key, now_ms: i64) !void {
        if (self.entries.count() >= self.max_entries and !self.entries.contains(key)) self.purge(now_ms);
        if (self.entries.count() < self.max_entries or self.entries.contains(key)) try self.entries.put(key, now_ms);
    }
    fn active(self: *Blacklist, key: Key, now_ms: i64) bool {
        const created = self.entries.get(key) orelse return false;
        if (created < 0) return true;
        if (now_ms - created < self.ttl_ms) return true;
        _ = self.entries.remove(key);
        return false;
    }
};

test "blacklist accepts IP and endpoint blocks, then expires them" {
    var blacklist = Blacklist.init(std.testing.allocator, 2, 100);
    defer blacklist.deinit();
    const address = Address{ .ip = .{ .v4 = .{ 1, 2, 3, 4 } }, .port = 1 };
    try blacklist.insertAddress(address, 0);
    try std.testing.expect(blacklist.contains(address, 50));
    try std.testing.expect(!blacklist.contains(address, 100));
}

test "blacklist deduplicates repeated keys at capacity" {
    var blacklist = Blacklist.init(std.testing.allocator, 1, 100);
    defer blacklist.deinit();
    const address = Address{ .ip = .{ .v4 = .{ 1, 2, 3, 4 } }, .port = 1 };
    try blacklist.insertAddress(address, 0);
    try blacklist.insertAddress(address, 50);
    try std.testing.expectEqual(@as(usize, 1), blacklist.entries.count());
    try std.testing.expect(blacklist.contains(address, 149));
    try std.testing.expect(!blacklist.contains(address, 150));
}
