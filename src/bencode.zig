const std = @import("std");

pub const Error = error{ InvalidValue, InvalidInteger, UnterminatedValue, TrailingData, OutputTooSmall, NestingTooDeep };

pub const Value = union(enum) {
    bytes: []const u8,
    integer: i64,
    list: std.ArrayList(Value),
    dict: std.ArrayList(Entry),

    pub const Entry = struct { key: []const u8, value: Value };

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .list => |*items| {
                for (items.items) |*item| item.deinit(allocator);
                items.deinit(allocator);
            },
            .dict => |*entries| {
                for (entries.items) |*entry| entry.value.deinit(allocator);
                entries.deinit(allocator);
            },
            else => {},
        }
    }

    pub fn get(self: *const Value, key: []const u8) ?*const Value {
        if (self.* != .dict) return null;
        for (self.dict.items) |*entry| if (std.mem.eql(u8, key, entry.key)) return &entry.value;
        return null;
    }
};

pub const Parser = struct {
    input: []const u8,
    cursor: usize = 0,
    depth: usize = 0,
    allocator: std.mem.Allocator,

    pub const max_depth = 64;

    /// Strings and keys refer to input; keep it valid while reading the tree.
    /// Release list/dictionary storage with Value.deinit using this allocator.
    pub fn parse(allocator: std.mem.Allocator, input: []const u8) (Error || std.mem.Allocator.Error)!Value {
        var parser = Parser{ .input = input, .allocator = allocator };
        var parsed = try parser.value();
        errdefer parsed.deinit(allocator);
        if (parser.cursor != input.len) return error.TrailingData;
        return parsed;
    }

    pub fn value(self: *Parser) (Error || std.mem.Allocator.Error)!Value {
        if (self.cursor >= self.input.len) return error.UnterminatedValue;
        if (self.depth >= max_depth) return error.NestingTooDeep;
        self.depth += 1;
        defer self.depth -= 1;
        return switch (self.input[self.cursor]) {
            '0'...'9' => .{ .bytes = try self.string() },
            'i' => .{ .integer = try self.integer() },
            'l' => self.list(),
            'd' => self.dict(),
            else => error.InvalidValue,
        };
    }

    fn string(self: *Parser) Error![]const u8 {
        const start = self.cursor;
        var length: usize = 0;
        while (self.cursor < self.input.len and self.input[self.cursor] != ':') : (self.cursor += 1) {
            const byte = self.input[self.cursor];
            if (byte < '0' or byte > '9') return error.InvalidValue;
            length = std.math.mul(usize, length, 10) catch return error.InvalidValue;
            length = std.math.add(usize, length, byte - '0') catch return error.InvalidValue;
        }
        if (self.cursor == start or self.cursor == self.input.len) return error.UnterminatedValue;
        if (self.cursor - start > 1 and self.input[start] == '0') return error.InvalidValue;
        self.cursor += 1;
        const end = std.math.add(usize, self.cursor, length) catch return error.InvalidValue;
        if (end > self.input.len) return error.UnterminatedValue;
        defer self.cursor = end;
        return self.input[self.cursor..end];
    }

    fn integer(self: *Parser) Error!i64 {
        self.cursor += 1;
        const start = self.cursor;
        while (self.cursor < self.input.len and self.input[self.cursor] != 'e') : (self.cursor += 1) {}
        if (self.cursor == self.input.len or start == self.cursor) return error.UnterminatedValue;
        const digits = self.input[start..self.cursor];
        const negative = digits[0] == '-';
        const magnitude = if (negative) digits[1..] else digits;
        if (magnitude.len == 0 or (magnitude.len > 1 and magnitude[0] == '0') or (negative and magnitude[0] == '0')) return error.InvalidInteger;
        for (magnitude) |byte| if (byte < '0' or byte > '9') return error.InvalidInteger;
        const result = std.fmt.parseInt(i64, digits, 10) catch return error.InvalidInteger;
        self.cursor += 1;
        return result;
    }

    fn list(self: *Parser) (Error || std.mem.Allocator.Error)!Value {
        self.cursor += 1;
        var items: std.ArrayList(Value) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }
        while (self.cursor < self.input.len and self.input[self.cursor] != 'e') {
            var item = try self.value();
            items.append(self.allocator, item) catch |err| {
                item.deinit(self.allocator);
                return err;
            };
        }
        if (self.cursor == self.input.len) return error.UnterminatedValue;
        self.cursor += 1;
        return .{ .list = items };
    }

    fn dict(self: *Parser) (Error || std.mem.Allocator.Error)!Value {
        self.cursor += 1;
        var entries: std.ArrayList(Value.Entry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.value.deinit(self.allocator);
            entries.deinit(self.allocator);
        }
        while (self.cursor < self.input.len and self.input[self.cursor] != 'e') {
            const key = try self.string();
            for (entries.items) |entry| if (std.mem.eql(u8, entry.key, key)) return error.InvalidValue;
            var child = try self.value();
            entries.append(self.allocator, .{ .key = key, .value = child }) catch |err| {
                child.deinit(self.allocator);
                return err;
            };
        }
        if (self.cursor == self.input.len) return error.UnterminatedValue;
        self.cursor += 1;
        return .{ .dict = entries };
    }
};

pub fn encodeString(writer: anytype, bytes: []const u8) !void {
    try writer.print("{d}:", .{bytes.len});
    try writer.writeAll(bytes);
}

pub fn encode(writer: anytype, value: Value) !void {
    switch (value) {
        .bytes => |bytes| try encodeString(writer, bytes),
        .integer => |integer| try writer.print("i{d}e", .{integer}),
        .list => |items| {
            try writer.writeByte('l');
            for (items.items) |item| try encode(writer, item);
            try writer.writeByte('e');
        },
        .dict => |entries| {
            try writer.writeByte('d');
            // Dictionaries are usually tiny. Selecting the next key avoids a
            // temporary allocation on every KRPC packet.
            var previous: ?usize = null;
            var emitted: usize = 0;
            while (emitted < entries.items.len) : (emitted += 1) {
                var next: ?usize = null;
                for (entries.items, 0..) |entry, index| {
                    if (previous) |prior| {
                        const order = std.mem.order(u8, entry.key, entries.items[prior].key);
                        if (order == .lt or (order == .eq and index <= prior)) continue;
                    }
                    if (next) |best| {
                        if (std.mem.order(u8, entry.key, entries.items[best].key) != .lt) continue;
                    }
                    next = index;
                }
                const entry = entries.items[next orelse return error.InvalidValue];
                try encodeString(writer, entry.key);
                try encode(writer, entry.value);
                previous = next;
            }
            try writer.writeByte('e');
        },
    }
}

pub fn validate(input: []const u8) (Error || std.mem.Allocator.Error)!void {
    var parser = Parser{ .input = input, .allocator = std.heap.page_allocator };
    var value = try parser.value();
    defer value.deinit(std.heap.page_allocator);
    if (parser.cursor != input.len) return error.TrailingData;
}

test "parses bencode values recursively" {
    var value = try Parser.parse(std.testing.allocator, "d1:ali1e3:twoe1:b5:helloe");
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", value.get("b").?.bytes);
    try std.testing.expectEqual(@as(i64, 1), value.get("a").?.list.items[0].integer);
}

test "repeatedly releases nested values through borrowed pointers" {
    const payload = "d1:ad1:xld1:yi1eeee1:q4:ping1:t2:aa1:y1:qe";
    var iteration: usize = 0;
    while (iteration < 1_000) : (iteration += 1) {
        var value = try Parser.parse(std.testing.allocator, payload);
        defer value.deinit(std.testing.allocator);
        const args = value.get("a").?;
        try std.testing.expect(args.get("id") == null);
        try std.testing.expect(args.get("x").?.list.items[0].dict.items.len == 1);
    }
}

test "parser rejects malformed and trailing input without leaking containers" {
    try std.testing.expectError(error.UnterminatedValue, Parser.parse(std.testing.allocator, "d1:ali1e"));
    try std.testing.expectError(error.TrailingData, Parser.parse(std.testing.allocator, "i1ei2e"));
    try std.testing.expectError(error.InvalidInteger, Parser.parse(std.testing.allocator, "i1xe"));
    try std.testing.expectError(error.InvalidValue, Parser.parse(std.testing.allocator, "x"));
}

test "encoder emits canonical dictionary key order" {
    var entries: std.ArrayList(Value.Entry) = .empty;
    defer entries.deinit(std.testing.allocator);
    try entries.append(std.testing.allocator, .{ .key = "z", .value = .{ .integer = 1 } });
    try entries.append(std.testing.allocator, .{ .key = "a", .value = .{ .integer = 2 } });
    var output: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try encode(&writer, .{ .dict = entries });
    try std.testing.expectEqualStrings("d1:ai2e1:zi1ee", writer.buffered());
}
