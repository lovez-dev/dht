//! Real sockets: run this suite only on the designated test host.
const std = @import("std");
const dht = @import("dht");
const io = std.testing.io;
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .{ .nanoseconds = 3 * std.time.ns_per_s }, .clock = .awake } };

fn loopback(port: u16) std.Io.net.IpAddress {
    return .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
}
fn endpoint(port: u16) dht.Address {
    return .{ .ip = .{ .v4 = .{ 127, 0, 0, 1 } }, .port = port };
}
fn udp() !std.Io.net.Socket {
    const address = loopback(0);
    return address.bind(io, .{ .mode = .dgram, .protocol = .udp });
}
fn now() i64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).toMilliseconds());
}

test "UDP answers ping and survives malformed packet" {
    var server = dht.Server.init(a, @splat(1));
    defer server.deinit();
    server.table.allow_private_addresses = true;
    var prng = std.Random.DefaultPrng.init(2);
    var random = prng.random();
    var service = try dht.UdpService.bind(io, &server, &random, 0, .udp4);
    defer service.deinit();
    var client = try udp();
    defer client.close(io);
    const address = loopback(service.port());
    try client.send(io, &address, "malformed");
    try expect(!try service.handleOnce(timeout));
    try client.send(io, &address, "d1:ad2:id20:abcdefghijklmnopqrste1:q4:ping1:t2:aa1:y1:qe");
    try expect(try service.handleOnce(timeout));
    var bytes: [512]u8 = undefined;
    const incoming = try client.receiveTimeout(io, &bytes, timeout);
    var response = try dht.bencode.Parser.parse(a, incoming.data);
    defer response.deinit(a);
    try std.testing.expectEqualStrings("aa", response.get("t").?.bytes);
    try std.testing.expectEqualStrings("r", response.get("y").?.bytes);
    try equal(@as(usize, 1), server.table.nodes.items.len);
}

test "standard maintenance retransmits exact payload then expires and unblocks query" {
    var prng = std.Random.DefaultPrng.init(3);
    var node = try dht.StandardDht.init(a, io, .{ .bootstrap_nodes = &.{}, .allow_private_addresses = true }, prng.random());
    defer node.deinit();
    var service = try dht.UdpService.bind(io, &node.server, &node.random, 0, .udp4);
    defer service.deinit();
    service.allow_private_addresses = true;
    var client = try udp();
    defer client.close(io);
    const address = endpoint(client.address.getPort());
    const started = now();
    try node.findNode(&service, address, @splat(9));
    var first: [256]u8 = undefined;
    const sent = try client.receiveTimeout(io, &first, timeout);
    const first_len = sent.data.len;
    try node.maintain(&service, started + 16000);
    var second: [256]u8 = undefined;
    const resent = try client.receiveTimeout(io, &second, timeout);
    try std.testing.expectEqualSlices(u8, first[0..first_len], resent.data);
    try node.maintain(&service, started + 32000);
    try equal(@as(usize, 0), node.server.transactions.pending.count());
    try equal(@as(usize, 0), node.server.transactions.index.count());
    try equal(@as(usize, 0), node.server.transactions.deadlines.items.len);
    try expect(node.server.blacklist.contains(address, started + 32000));
}

test "failed send rolls back pending transaction" {
    var prng = std.Random.DefaultPrng.init(4);
    var node = try dht.StandardDht.init(a, io, .{ .bootstrap_nodes = &.{} }, prng.random());
    defer node.deinit();
    var service = try dht.UdpService.bind(io, &node.server, &node.random, 0, .udp4);
    defer service.deinit();
    try std.testing.expectError(error.InvalidDestination, node.findNode(&service, endpoint(1), @splat(2)));
    try equal(@as(usize, 0), node.server.transactions.pending.count());
    try equal(@as(usize, 0), node.server.transactions.index.count());
}

test "standard bootstrap recursively queries discovered contact over UDP" {
    var bootstrap = try udp();
    defer bootstrap.close(io);
    var discovered = try udp();
    defer discovered.close(io);
    const nodes = [_]dht.Address{endpoint(bootstrap.address.getPort())};
    var prng = std.Random.DefaultPrng.init(5);
    var node = try dht.StandardDht.init(a, io, .{ .port = 0, .bootstrap_nodes = &nodes, .allow_private_addresses = true }, prng.random());
    defer node.deinit();
    var task = try io.concurrent(dht.StandardDht.run, .{ &node, io });
    defer task.cancel(io) catch {};
    var bytes: [512]u8 = undefined;
    const incoming = try bootstrap.receiveTimeout(io, &bytes, timeout);
    var request = try dht.bencode.Parser.parse(a, incoming.data);
    defer request.deinit(a);
    var compact: [26]u8 = undefined;
    @memset(compact[0..20], 0x77);
    compact[20..24].* = .{ 127, 0, 0, 1 };
    std.mem.writeInt(u16, compact[24..26], discovered.address.getPort(), .big);
    var packet: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&packet);
    try writer.writeAll("d1:rd2:id20:abcdefghijklmnopqrst5:nodes26:");
    try writer.writeAll(&compact);
    try writer.writeAll("e1:t");
    try dht.bencode.encodeString(&writer, request.get("t").?.bytes);
    try writer.writeAll("1:y1:re");
    try bootstrap.send(io, &incoming.from, writer.buffered());
    const recursive = try discovered.receiveTimeout(io, &bytes, timeout);
    var query = try dht.bencode.Parser.parse(a, recursive.data);
    defer query.deinit(a);
    try std.testing.expectEqualStrings("find_node", query.get("q").?.bytes);
    node.stop();
    try task.await(io);
    try expect(!node.stat().running);
    try expect(node.stat().nodes >= 2);
}

test "two queued info hashes are sent to the same contact" {
    var contact = try udp();
    defer contact.close(io);
    var prng = std.Random.DefaultPrng.init(6);
    var node = try dht.StandardDht.init(a, io, .{ .bootstrap_nodes = &.{}, .allow_private_addresses = true }, prng.random());
    defer node.deinit();
    _ = try node.server.table.insert(.{ .id = @splat(8), .address = endpoint(contact.address.getPort()), .last_active_ms = now() });
    try node.getPeers(@splat(1));
    try node.getPeers(@splat(2));
    var service = try dht.UdpService.bind(io, &node.server, &node.random, 0, .udp4);
    defer service.deinit();
    service.allow_private_addresses = true;
    try node.maintain(&service, now());
    var bytes: [256]u8 = undefined;
    for (1..3) |expected| {
        const incoming = try contact.receiveTimeout(io, &bytes, timeout);
        var query = try dht.bencode.Parser.parse(a, incoming.data);
        defer query.deinit(a);
        try std.testing.expectEqualStrings("get_peers", query.get("q").?.bytes);
        try equal(@as(u8, @intCast(expected)), query.get("a").?.get("info_hash").?.bytes[0]);
    }
    try equal(@as(usize, 2), node.server.transactions.pending.count());
}

test "lookup admission survives transaction capacity backpressure" {
    var contact = try udp();
    defer contact.close(io);
    var prng = std.Random.DefaultPrng.init(10);
    var node = try dht.StandardDht.init(a, io, .{ .bootstrap_nodes = &.{}, .allow_private_addresses = true, .max_pending_queries = 1 }, prng.random());
    defer node.deinit();
    const address = endpoint(contact.address.getPort());
    _ = try node.server.table.insert(.{ .id = @splat(8), .address = address, .last_active_ms = now() });
    try node.getPeers(@splat(1));
    try node.getPeers(@splat(2));
    var service = try dht.UdpService.bind(io, &node.server, &node.random, 0, .udp4);
    defer service.deinit();
    service.allow_private_addresses = true;
    for (1..3) |expected| {
        try node.maintain(&service, now());
        var bytes: [256]u8 = undefined;
        const incoming = try contact.receiveTimeout(io, &bytes, timeout);
        var query = try dht.bencode.Parser.parse(a, incoming.data);
        defer query.deinit(a);
        try equal(@as(u8, @intCast(expected)), query.get("a").?.get("info_hash").?.bytes[0]);
        const id = std.mem.readVarInt(u32, query.get("t").?.bytes, .big);
        try expect(node.server.transactions.take(id, address) != null);
    }
}

test "IPv6 UDP ping round trip" {
    var server = dht.Server.init(a, @splat(1));
    defer server.deinit();
    var prng = std.Random.DefaultPrng.init(11);
    var random = prng.random();
    var service = try dht.UdpService.bind(io, &server, &random, 0, .udp6);
    defer service.deinit();
    const local = try std.Io.net.IpAddress.parse("::1", 0);
    var client = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer client.close(io);
    const destination = try std.Io.net.IpAddress.parse("::1", service.port());
    try client.send(io, &destination, "d1:ad2:id20:abcdefghijklmnopqrste1:q4:ping1:t2:aa1:y1:qe");
    try expect(try service.handleOnce(timeout));
    var bytes: [512]u8 = undefined;
    const incoming = try client.receiveTimeout(io, &bytes, timeout);
    var reply = try dht.bencode.Parser.parse(a, incoming.data);
    defer reply.deinit(a);
    try std.testing.expectEqualStrings("aa", reply.get("t").?.bytes);
}

test "UDP token permits repeated announces and peers expire" {
    var server = dht.Server.init(a, @splat(1));
    defer server.deinit();
    server.table.allow_private_addresses = true;
    var prng = std.Random.DefaultPrng.init(12);
    var random = prng.random();
    var service = try dht.UdpService.bind(io, &server, &random, 0, .udp4);
    defer service.deinit();
    var client = try udp();
    defer client.close(io);
    const address = loopback(service.port());
    try client.send(io, &address, "d1:ad2:id20:abcdefghijklmnopqrst9:info_hash20:12345678901234567890e1:q9:get_peers1:t2:aa1:y1:qe");
    try expect(try service.handleOnce(timeout));
    var bytes: [512]u8 = undefined;
    const incoming = try client.receiveTimeout(io, &bytes, timeout);
    var reply = try dht.bencode.Parser.parse(a, incoming.data);
    defer reply.deinit(a);
    const token = try a.dupe(u8, reply.get("r").?.get("token").?.bytes);
    defer a.free(token);
    for (0..2) |_| {
        var packet: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&packet);
        try writer.writeAll("d1:ad2:id20:abcdefghijklmnopqrst12:implied_porti1e9:info_hash20:123456789012345678904:porti1e5:token");
        try dht.bencode.encodeString(&writer, token);
        try writer.writeAll("e1:q13:announce_peer1:t2:ab1:y1:qe");
        try client.send(io, &address, writer.buffered());
        try expect(try service.handleOnce(timeout));
        _ = try client.receiveTimeout(io, &bytes, timeout);
    }
    const hash: dht.NodeId = "12345678901234567890".*;
    const peers = server.peers.get(hash).?;
    try equal(@as(usize, 1), peers.items.len);
    try equal(client.address.getPort(), peers.items[0].port);
    server.purgePeers(now() + server.peer_ttl_ms + 1);
    try equal(@as(usize, 0), server.peers.count());
}

const MetadataPeer = struct {
    server: std.Io.net.Server,
    metadata: []const u8,
    reject: bool = false,
    wrong_hash: bool = false,
    stall: bool = false,
    fn run(self: *MetadataPeer) !void {
        var stream = try self.server.accept(io);
        defer stream.close(io);
        if (self.stall) return io.sleep(.fromSeconds(30), .awake);
        var rb: [32768]u8 = undefined;
        var reader = stream.reader(io, &rb);
        var wb: [32768]u8 = undefined;
        var writer = stream.writer(io, &wb);
        var handshake: [68]u8 = undefined;
        try reader.interface.readSliceAll(&handshake);
        if (self.wrong_hash) handshake[28] ^= 1;
        try writer.interface.writeAll(&handshake);
        try writer.interface.flush();
        if (self.wrong_hash) return;
        const extension = try readFrame(&reader.interface);
        defer a.free(extension);
        var payload: [128]u8 = undefined;
        var out = std.Io.Writer.fixed(&payload);
        try out.print("{c}{c}d1:md11:ut_metadatai7ee13:metadata_sizei{d}ee", .{ @as(u8, 20), @as(u8, 0), self.metadata.len });
        try writeFrame(&writer.interface, out.buffered());
        try writer.interface.flush();
        const pieces = try dht.peerwire.metadataPieces(self.metadata.len);
        for (0..pieces) |_| {
            const request = try readFrame(&reader.interface);
            defer a.free(request);
            try equal(@as(u8, 20), request[0]);
            try equal(@as(u8, 7), request[1]);
        }
        // Remote mapping is 7, our advertised receive mapping is 1.
        for (0..pieces) |offset| {
            const index = pieces - offset - 1;
            var frame: [dht.peerwire.block_size + 256]u8 = undefined;
            var message = std.Io.Writer.fixed(&frame);
            try message.writeAll(&.{ 20, 1 });
            try message.print("d8:msg_typei{d}e5:piecei{d}ee", .{ @as(u8, if (self.reject) 2 else 1), index });
            if (!self.reject) try message.writeAll(self.metadata[index * dht.peerwire.block_size .. @min(self.metadata.len, (index + 1) * dht.peerwire.block_size)]);
            try writeFrame(&writer.interface, message.buffered());
            try writer.interface.flush();
            if (self.reject) return;
        }
    }
};
fn readFrame(reader: *std.Io.Reader) ![]u8 {
    var length: [4]u8 = undefined;
    try reader.readSliceAll(&length);
    const size = std.mem.readInt(u32, &length, .big);
    if (size > dht.peerwire.block_size + 4096) return error.OversizedFrame;
    const bytes = try a.alloc(u8, size);
    errdefer a.free(bytes);
    try reader.readSliceAll(bytes);
    return bytes;
}
fn writeFrame(writer: *std.Io.Writer, bytes: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(bytes.len), .big);
    try writer.writeAll(&length);
    try writer.writeAll(bytes);
}
fn metadataTest(reject: bool, wrong_hash: bool) !void {
    const address = loopback(0);
    const metadata = try a.alloc(u8, dht.peerwire.block_size + 17);
    defer a.free(metadata);
    @memset(metadata, 0x5a);
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(metadata, &hash, .{});
    var peer: MetadataPeer = .{ .server = try address.listen(io, .{}), .metadata = metadata, .reject = reject, .wrong_hash = wrong_hash };
    defer peer.server.deinit(io);
    var task = try io.concurrent(MetadataPeer.run, .{&peer});
    defer task.cancel(io) catch {};
    const target = loopback(peer.server.socket.address.getPort());
    if (reject) {
        try std.testing.expectError(error.MetadataRejected, dht.peerwire.fetchMetadata(a, io, target, hash, @splat(3)));
    } else if (wrong_hash) {
        try std.testing.expectError(error.InfoHashMismatch, dht.peerwire.fetchMetadata(a, io, target, hash, @splat(3)));
    } else {
        const actual = try dht.peerwire.fetchMetadata(a, io, target, hash, @splat(3));
        defer a.free(actual);
        try std.testing.expectEqualSlices(u8, metadata, actual);
    }
    try task.await(io);
}
test "TCP downloads out-of-order metadata with asymmetric extension ids" {
    try metadataTest(false, false);
}
test "TCP metadata rejection returns immediately" {
    try metadataTest(true, false);
}
test "TCP handshake for a different torrent is rejected" {
    try metadataTest(false, true);
}

test "Wire idle dispatch is cancelable and stop wakes response waiter" {
    var prng = std.Random.DefaultPrng.init(7);
    var wire = dht.Wire.init(a, io, prng.random());
    defer wire.deinit();
    var dispatch = try io.concurrent(dht.Wire.run, .{&wire});
    try io.sleep(.fromMilliseconds(20), .awake);
    const canceled = dispatch.cancel(io);
    try std.testing.expectError(error.Canceled, canceled);
    var waiter = try io.concurrent(dht.Wire.waitResponseCancelable, .{&wire});
    wire.stop();
    try expect((try waiter.await(io)) == null);
}

test "Wire stalled peer deadline returns its permit and records failure" {
    var prng = std.Random.DefaultPrng.init(8);
    var wire = dht.Wire.initWithConfig(a, io, prng.random(), .{
        .allow_private_addresses = true,
        .download_timeout_ms = 50,
        .worker_limit = 1,
    });
    defer wire.deinit();
    const address = loopback(0);
    var peer: MetadataPeer = .{ .server = try address.listen(io, .{}), .metadata = "unused", .stall = true };
    defer peer.server.deinit(io);
    var peer_task = try io.concurrent(MetadataPeer.run, .{&peer});
    defer peer_task.cancel(io) catch {};
    try wire.request(@splat(3), endpoint(peer.server.socket.address.getPort()));
    var dispatch = try io.concurrent(dht.Wire.run, .{&wire});
    defer dispatch.cancel(io) catch {};
    const deadline = now() + 3000;
    while (wire.stat().failed == 0 and now() < deadline) try io.sleep(.fromMilliseconds(10), .awake);
    try equal(@as(usize, 1), wire.stat().failed);
    try equal(@as(usize, 0), wire.stat().active);
    try equal(@as(usize, 1), wire.stat().blacklisted);
    wire.stop();
    try dispatch.await(io);
}

test "Wire stop releases a producer blocked on a full queue" {
    var prng = std.Random.DefaultPrng.init(9);
    var wire = dht.Wire.initWithConfig(a, io, prng.random(), .{ .request_queue_capacity = 1 });
    defer wire.deinit();
    const address: dht.Address = .{ .ip = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = 80 };
    try wire.request(@splat(1), address);
    try std.testing.expectError(error.QueueFull, wire.tryRequest(@splat(2), address));
    var producer = try io.concurrent(dht.Wire.request, .{ &wire, @as(dht.NodeId, @splat(2)), address });
    defer producer.cancel(io) catch {};
    try io.sleep(.fromMilliseconds(20), .awake);
    wire.stop();
    try std.testing.expectError(error.Stopped, producer.await(io));
}
