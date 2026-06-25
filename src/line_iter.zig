const std = @import("std");

pub const NewLineIterator = struct {
    buffer: []const u8,
    delimiter: u8 = '\n',
    index: usize = 0,

    const Self = @This();

    pub fn init(buf: []const u8) Self {
        return .{
            .buffer = buf,
        };
    }

    pub fn next(self: *Self) ?[]const u8 {
        const start = self.index;

        if (start >= self.buffer.len) return null;

        while (self.index < self.buffer.len) : (self.index += 1) {
            if (self.buffer[self.index] == self.delimiter) {
                self.index += 1;
                return self.buffer[start..self.index];
            }
        }
        self.index = self.buffer.len;
        return self.buffer[start..];
    }
};

test "NewLineIterator" {
    const test1: []const u8 = "Hello\nWorld";

    var iter = NewLineIterator{
        .buffer = test1,
    };

    try std.testing.expectEqualSlices(u8, "Hello\n", iter.next().?);
    try std.testing.expectEqualSlices(u8, "World", iter.next().?);
}

test "basic newline splitting" {
    const input = "Hello\nWorld";

    var it = NewLineIterator.init(input);

    try std.testing.expectEqualSlices(u8, "Hello\n", it.next().?);
    try std.testing.expectEqualSlices(u8, "World", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "trailing newline" {
    const input = "Hello\nWorld\n";

    var it = NewLineIterator.init(input);

    try std.testing.expectEqualSlices(u8, "Hello\n", it.next().?);
    try std.testing.expectEqualSlices(u8, "World\n", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "no newline at all" {
    const input = "HelloWorld";

    var it = NewLineIterator.init(input);

    try std.testing.expectEqualSlices(u8, "HelloWorld", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "empty input" {
    const input = "";

    var it = NewLineIterator.init(input);

    try std.testing.expect(it.next() == null);
}

test "multiple consecutive newlines" {
    const input = "A\n\nB\n";

    var it = NewLineIterator.init(input);

    try std.testing.expectEqualSlices(u8, "A\n", it.next().?);
    try std.testing.expectEqualSlices(u8, "\n", it.next().?);
    try std.testing.expectEqualSlices(u8, "B\n", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "single character lines" {
    const input = "a\nb\nc\n";

    var it = NewLineIterator.init(input);

    try std.testing.expectEqualSlices(u8, "a\n", it.next().?);
    try std.testing.expectEqualSlices(u8, "b\n", it.next().?);
    try std.testing.expectEqualSlices(u8, "c\n", it.next().?);
    try std.testing.expect(it.next() == null);
}
