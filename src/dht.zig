//! BitTorrent Mainline DHT, peer discovery, and verified metadata retrieval.
pub const bencode = @import("bencode.zig");
pub const routing = @import("routing.zig");
pub const krpc = @import("krpc.zig");
pub const peerwire = @import("peerwire.zig");
pub const blacklist = @import("blacklist.zig");
pub const transaction = @import("transaction.zig");
pub const runtime = @import("runtime.zig");
pub const api = @import("api.zig");
pub const wire = @import("wire.zig");

pub const NodeId = routing.NodeId;
pub const Address = routing.Address;
pub const Node = routing.Node;
pub const Peer = routing.Peer;
pub const RoutingTable = routing.RoutingTable;
pub const Server = krpc.Server;
pub const Blacklist = blacklist.Blacklist;
pub const TransactionManager = transaction.Manager;
pub const UdpService = runtime.UdpService;
pub const Dht = api.Dht;
pub const StandardDht = api.StandardDht;
pub const CrawlConfig = api.CrawlConfig;
pub const StandardConfig = api.StandardConfig;
pub const Wire = wire.Wire;

pub const CompactAddress = struct {
    bytes: [6]u8,
    pub fn init(address_ip: [4]u8, address_port: u16) CompactAddress {
        return .{ .bytes = .{ address_ip[0], address_ip[1], address_ip[2], address_ip[3], @truncate(address_port >> 8), @truncate(address_port) } };
    }
    pub fn ip(self: CompactAddress) [4]u8 {
        return self.bytes[0..4].*;
    }
    pub fn port(self: CompactAddress) u16 {
        return (@as(u16, self.bytes[4]) << 8) | self.bytes[5];
    }
};

pub fn integerToBytes(value: u64, output: *[8]u8) []const u8 {
    @import("std").mem.writeInt(u64, output, value, .big);
    var start: usize = 0;
    while (start < 7 and output[start] == 0) : (start += 1) {}
    return output[start..];
}

test {
    _ = bencode;
    _ = routing;
    _ = krpc;
    _ = peerwire;
    _ = blacklist;
    _ = transaction;
    _ = runtime;
    _ = api;
    _ = wire;
}
