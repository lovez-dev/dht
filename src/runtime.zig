const std = @import("std");
const Io = std.Io;
const bencode = @import("bencode.zig");
const krpc = @import("krpc.zig");
const routing = @import("routing.zig");

/// A blocking UDP service loop for a KRPC server. Run it in an application
/// worker thread when the process has other work to do.
pub const UdpService = struct {
    io: Io,
    socket: Io.net.Socket,
    server: *krpc.Server,
    random: *std.Random,
    allow_private_addresses: bool = false,

    pub const Network = enum { udp4, udp6 };
    pub fn bind(io: Io, server: *krpc.Server, random: *std.Random, listen_port: u16, network: Network) !UdpService {
        const address: Io.net.IpAddress = switch (network) {
            .udp4 => .{ .ip4 = .unspecified(listen_port) },
            .udp6 => .{ .ip6 = .unspecified(listen_port) },
        };
        return .{ .io = io, .socket = try Io.net.IpAddress.bind(&address, io, .{ .mode = .dgram, .protocol = .udp }), .server = server, .random = random };
    }
    pub fn deinit(self: *UdpService) void {
        self.socket.close(self.io);
    }
    pub fn port(self: *const UdpService) u16 {
        return self.socket.address.getPort();
    }
    pub fn send(self: *const UdpService, destination: routing.Address, payload: []const u8) !void {
        if (!routing.isRoutable(destination) and !(self.allow_private_addresses and routing.isUnicast(destination))) return error.InvalidDestination;
        const now_ms: i64 = @intCast(std.Io.Timestamp.now(self.io, .awake).toMilliseconds());
        if (self.server.blacklist.contains(destination, now_ms)) return error.Blacklisted;
        const address = toIpAddress(destination);
        try self.socket.send(self.io, &address, payload);
    }
    pub fn handleOnce(self: *UdpService, timeout: Io.Timeout) !bool {
        var input: [4096]u8 = undefined;
        const incoming = self.socket.receiveTimeout(self.io, &input, timeout) catch |err| switch (err) {
            error.Timeout => return false,
            else => return err,
        };
        const source = toAddress(incoming.from) orelse return false;
        if (self.server.blacklist.contains(source, @intCast(std.Io.Timestamp.now(self.io, .awake).toMilliseconds()))) return false;
        var output: [4096]u8 = undefined;
        const now_ms: i64 = @intCast(std.Io.Timestamp.now(self.io, .awake).toMilliseconds());
        // A parsed KRPC tree only exists for this datagram. An arena makes all
        // parser allocations one batch release at the end of the handler.
        var packet_arena = std.heap.ArenaAllocator.init(self.server.allocator);
        defer packet_arena.deinit();
        var parsed = bencode.Parser.parse(packet_arena.allocator(), incoming.data) catch {
            return false;
        };
        const kind = parsed.get("y") orelse {
            return false;
        };
        if (kind.* == .bytes and std.mem.eql(u8, kind.bytes, "r")) {
            self.server.handleParsedResponse(source, now_ms, &parsed) catch {
                return false;
            };
            return true;
        }
        if (kind.* == .bytes and std.mem.eql(u8, kind.bytes, "e")) {
            self.server.handleParsedError(source, &parsed) catch return false;
            return true;
        }
        const response = self.server.handleParsedDatagram(self.random, source, now_ms, &parsed, &output) catch {
            return false;
        };
        if (response.len == 0) return true;
        const destination = toIpAddress(source);
        try self.socket.send(self.io, &destination, response);
        return true;
    }
    pub fn run(self: *UdpService) !void {
        while (true) _ = try self.handleOnce(.{ .duration = .{ .raw = .{ .nanoseconds = std.time.ns_per_s }, .clock = .awake } });
    }
};

fn toAddress(address: Io.net.IpAddress) ?routing.Address {
    return switch (address) {
        .ip4 => |ip4| .{ .ip = .{ .v4 = ip4.bytes }, .port = ip4.port },
        .ip6 => |ip6| .{ .ip = .{ .v6 = ip6.bytes }, .port = ip6.port },
    };
}
fn toIpAddress(address: routing.Address) Io.net.IpAddress {
    return switch (address.ip) {
        .v4 => |ip| .{ .ip4 = .{ .bytes = ip, .port = address.port } },
        .v6 => |ip| .{ .ip6 = .{ .bytes = ip, .port = address.port } },
    };
}
