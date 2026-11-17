const std = @import("std");
const dht = @import("dht");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "serve")) {
        const port = try std.fmt.parseInt(u16, args[2], 10);
        var id: dht.NodeId = undefined;
        var seed: [32]u8 = undefined;
        try init.io.randomSecure(&seed);
        var prng = std.Random.DefaultCsprng.init(seed);
        var random = prng.random();
        random.bytes(&id);
        var server = dht.Server.init(init.arena.allocator(), id);
        defer server.deinit();
        var service = try dht.UdpService.bind(init.io, &server, &random, port, .udp4);
        defer service.deinit();
        std.log.info("DHT UDP service listening on 0.0.0.0:{d}", .{service.port()});
        try service.run();
    }
    std.log.info("Usage: dht-server serve <port>", .{});
}
