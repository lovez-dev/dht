const std = @import("std");
const bencode = @import("bencode.zig");

pub const block_size = 16 * 1024;
pub const max_metadata_size = block_size * 1000;
pub const handshake_prefix = "\x13BitTorrent protocol\x00\x00\x00\x00\x00\x10\x00\x01";

pub fn makeHandshake(info_hash: [20]u8, peer_id: [20]u8) [68]u8 {
    var result: [68]u8 = undefined;
    @memcpy(result[0..28], handshake_prefix);
    @memcpy(result[28..48], &info_hash);
    @memcpy(result[48..68], &peer_id);
    return result;
}
pub fn validateHandshake(data: []const u8) !void {
    if (data.len != 68 or !std.mem.eql(u8, data[0..20], handshake_prefix[0..20]) or data[25] & 0x10 == 0) return error.InvalidHandshake;
}
pub fn metadataPieces(metadata_size: usize) !usize {
    if (metadata_size == 0 or metadata_size > max_metadata_size) return error.InvalidMetadataSize;
    return std.math.divCeil(usize, metadata_size, block_size) catch unreachable;
}
pub fn parseExtendedHandshake(allocator: std.mem.Allocator, payload: []const u8) !struct { ut_metadata: i64, metadata_size: usize } {
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    var value = try bencode.Parser.parse(parse_arena.allocator(), payload);
    const mapping = value.get("m") orelse return error.InvalidHandshake;
    const extension = mapping.get("ut_metadata") orelse return error.InvalidHandshake;
    const size = value.get("metadata_size") orelse return error.InvalidHandshake;
    if (extension.* != .integer or size.* != .integer or size.integer <= 0) return error.InvalidHandshake;
    return .{ .ut_metadata = extension.integer, .metadata_size = std.math.cast(usize, size.integer) orelse return error.InvalidMetadataSize };
}

/// Collects `ut_metadata` data blocks and verifies the advertised info hash.
pub const MetadataAssembler = struct {
    allocator: std.mem.Allocator,
    expected_hash: [20]u8,
    metadata_size: usize,
    piece_count: usize,
    metadata: []u8,
    received: []bool,

    pub fn init(allocator: std.mem.Allocator, expected_hash: [20]u8, metadata_size: usize) !MetadataAssembler {
        const count = try metadataPieces(metadata_size);
        const metadata = try allocator.alloc(u8, metadata_size);
        errdefer allocator.free(metadata);
        const received = try allocator.alloc(bool, count);
        @memset(received, false);
        return .{ .allocator = allocator, .expected_hash = expected_hash, .metadata_size = metadata_size, .piece_count = count, .metadata = metadata, .received = received };
    }
    pub fn deinit(self: *MetadataAssembler) void {
        self.allocator.free(self.metadata);
        self.allocator.free(self.received);
    }
    pub fn put(self: *MetadataAssembler, index: usize, data: []const u8) !void {
        if (index >= self.piece_count) return error.InvalidPiece;
        const offset = std.math.mul(usize, index, block_size) catch return error.InvalidPiece;
        const expected = if (index + 1 == self.piece_count) self.metadata_size - offset else block_size;
        if (data.len != expected) return error.InvalidPiece;
        @memcpy(self.metadata[offset .. offset + data.len], data);
        self.received[index] = true;
    }
    pub fn complete(self: *const MetadataAssembler) bool {
        for (self.received) |present| if (!present) return false;
        return true;
    }
    /// Returns a verified copy; the caller frees it with self.allocator.
    pub fn finalize(self: *MetadataAssembler) ![]u8 {
        if (!self.complete()) return error.IncompleteMetadata;

        // Revalidate the assembled pieces before copying.  Pieces normally
        // arrive through put(), but this boundary also protects against
        // malformed peer data and any later mutation of the assembler state.
        var total: usize = 0;
        for (self.received, 0..) |present, index| {
            if (!present) return error.IncompleteMetadata;
            const index_offset = std.math.mul(usize, index, block_size) catch return error.InvalidMetadataSize;
            if (index_offset >= self.metadata_size) return error.InvalidPiece;
            const expected = if (index + 1 == self.piece_count)
                self.metadata_size - index_offset
            else
                block_size;
            total = std.math.add(usize, total, expected) catch return error.InvalidMetadataSize;
        }
        if (total != self.metadata_size) return error.InvalidMetadataSize;

        const metadata = try self.allocator.alloc(u8, self.metadata_size);
        errdefer self.allocator.free(metadata);
        @memcpy(metadata, self.metadata);
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(metadata, &digest, .{});
        if (!std.mem.eql(u8, &digest, &self.expected_hash)) return error.InfoHashMismatch;
        return metadata;
    }
};

/// Downloads and verifies metadata from one BEP 10 capable TCP peer.
/// The caller frees the result with allocator. The connection closes on every
/// return path; cancellation and any external deadline use the supplied I/O.
pub fn fetchMetadata(allocator: std.mem.Allocator, io: std.Io, address: std.Io.net.IpAddress, info_hash: [20]u8, peer_id: [20]u8) ![]u8 {
    // The threaded backend does not implement TCP connect timeouts. Wire
    // applies a cancelable deadline around the complete download instead.
    var stream = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp, .timeout = .none });
    defer stream.close(io);
    var reader_buffer: [32 * 1024]u8 = undefined;
    var reader = stream.reader(io, &reader_buffer);
    var writer_buffer: [32 * 1024]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    const handshake = makeHandshake(info_hash, peer_id);
    try writer.interface.writeAll(&handshake);
    try writer.interface.flush();
    var peer_handshake: [68]u8 = undefined;
    try reader.interface.readSliceAll(&peer_handshake);
    try validateHandshake(&peer_handshake);
    if (!std.mem.eql(u8, peer_handshake[28..48], &info_hash)) return error.InfoHashMismatch;
    var ext: [128]u8 = undefined;
    var ext_writer = std.Io.Writer.fixed(&ext);
    try ext_writer.writeAll(&.{ 20, 0 });
    try ext_writer.writeAll("d1:md11:ut_metadatai1eee");
    try writeMessage(&writer.interface, ext_writer.buffered());
    try writer.interface.flush();
    const negotiated = handshake: while (true) {
        const message = try readMessage(allocator, &reader.interface);
        const result = blk: {
            defer allocator.free(message);
            if (message.len < 2 or message[0] != 20 or message[1] != 0) continue;
            break :blk try parseExtendedHandshake(allocator, message[2..]);
        };
        break :handshake result;
    };
    if (negotiated.ut_metadata <= 0 or negotiated.ut_metadata > std.math.maxInt(u8)) return error.InvalidHandshake;
    var assembler = try MetadataAssembler.init(allocator, info_hash, negotiated.metadata_size);
    defer assembler.deinit();
    var piece: usize = 0;
    while (piece < assembler.piece_count) : (piece += 1) {
        var request_buf: [128]u8 = undefined;
        var request = std.Io.Writer.fixed(&request_buf);
        try request.writeByte(20);
        try request.writeByte(@intCast(negotiated.ut_metadata));
        try request.print("d8:msg_typei0e5:piecei{d}ee", .{piece});
        try writeMessage(&writer.interface, request.buffered());
        try writer.interface.flush();
    }
    while (!assembler.complete()) {
        const message = try readMessage(allocator, &reader.interface);
        errdefer allocator.free(message);
        // Incoming extension ids use our advertised mapping (ut_metadata=1).
        if (message.len < 2 or message[0] != 20 or message[1] != 1) {
            allocator.free(message);
            continue;
        }
        const accepted = blk: {
            var header_arena = std.heap.ArenaAllocator.init(allocator);
            defer header_arena.deinit();
            var parser = bencode.Parser{ .input = message[2..], .allocator = header_arena.allocator() };
            var header = try parser.value();
            const msg_type = header.get("msg_type") orelse return error.InvalidPiece;
            const index = header.get("piece") orelse return error.InvalidPiece;
            if (msg_type.* != .integer or index.* != .integer or index.integer < 0) return error.InvalidPiece;
            if (msg_type.integer == 2) return error.MetadataRejected;
            if (msg_type.integer != 1) break :blk false;
            const piece_index: usize = @intCast(index.integer);
            if (piece_index >= assembler.piece_count) break :blk false;
            const payload_start = 2 + parser.cursor;
            if (payload_start > message.len) break :blk false;
            try assembler.put(piece_index, message[payload_start..]);
            break :blk true;
        };
        allocator.free(message);
        if (!accepted) continue;
    }
    const metadata = try assembler.finalize();
    return metadata;
}

fn writeMessage(writer: *std.Io.Writer, payload: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(payload.len), .big);
    try writer.writeAll(&length);
    try writer.writeAll(payload);
}
fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var length: [4]u8 = undefined;
    try reader.readSliceAll(&length);
    const size = std.mem.readInt(u32, &length, .big);
    if (size > block_size + 4096) return error.MessageTooLarge;
    const message = try allocator.alloc(u8, size);
    errdefer allocator.free(message);
    try reader.readSliceAll(message);
    return message;
}

test "peer wire handshake and metadata size" {
    const message = makeHandshake(@as([20]u8, @splat(1)), @as([20]u8, @splat(2)));
    try validateHandshake(&message);
    try std.testing.expectEqual(@as(usize, 2), try metadataPieces(block_size + 1));
}

test "metadata assembler validates piece boundaries and hash" {
    const data = "hello";
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &digest, .{});
    var assembler = try MetadataAssembler.init(std.testing.allocator, digest, data.len);
    defer assembler.deinit();
    try std.testing.expectError(error.InvalidPiece, assembler.put(1, data));
    try std.testing.expectError(error.InvalidPiece, assembler.put(0, "hell"));
    try assembler.put(0, data);
    const metadata = try assembler.finalize();
    defer std.testing.allocator.free(metadata);
    try std.testing.expectEqualStrings(data, metadata);
}

test "metadata assembler rejects corrupted stored piece during finalize" {
    const data = "hello";
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &digest, .{});
    var assembler = try MetadataAssembler.init(std.testing.allocator, digest, data.len);
    defer assembler.deinit();
    try assembler.put(0, data);

    // Keep the allocation intact while exposing an invalid stored slice.
    assembler.received[0] = false;
    try std.testing.expectError(error.IncompleteMetadata, assembler.finalize());
}
