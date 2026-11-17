const std = @import("std");
const dht = @import("dht");
pub fn main() !void {
    var value = try dht.bencode.Parser.parse(std.heap.page_allocator, "d4:name7:example6:lengthi1024ee");
    defer value.deinit(std.heap.page_allocator);
    std.debug.print("{s}: {d} bytes\n", .{ value.get("name").?.bytes, value.get("length").?.integer });
}
