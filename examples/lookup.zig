const std = @import("std");
const dht = @import("dht");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2 or args[1].len != 40) {
        std.debug.print("Usage: zig build lookup -- <40-character-info-hash>\n", .{});
        return;
    }
    var hash: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&hash, args[1]);
    var seed: [32]u8 = undefined;
    try init.io.randomSecure(&seed);
    var random = std.Random.DefaultCsprng.init(seed);
    var node = try dht.StandardDht.init(std.heap.smp_allocator, init.io, .{ .port = 0, .on_get_peers_response = onPeer }, random.random());
    defer node.deinit();
    try node.getPeers(hash);
    try node.run(init.io);
}
fn onPeer(_: ?*anyopaque, hash: dht.NodeId, peer: dht.Peer) void {
    switch (peer.ip) {
        .v4 => |ip| std.debug.print("{x} {d}.{d}.{d}.{d}:{d}\n", .{ hash, ip[0], ip[1], ip[2], ip[3], peer.port }),
        .v6 => |ip| std.debug.print("{x} [{x}]:{d}\n", .{ hash, ip, peer.port }),
    }
}
