const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Fuzz = struct {
    idx: usize,
    score: isize,
};

fn lessThan(_: void, a: Fuzz, b: Fuzz) bool {
    return a.score > b.score;
}

pub fn fuzzList(list: []const []const u8, sequence: []const u8, allocator: Allocator) ![]Fuzz {
    var fuzz_list: std.ArrayList(Fuzz) = .empty;

    for (list, 0..) |string, i| {
        var iter = FuzzIterator{ .sequence = sequence, .buffer = string };

        var score: isize = 0;
        var found = false;
        while (iter.next()) |idx| {
            found = true;
            score += @as(isize, @intCast(sequence.len)) - @as(isize, @intCast(idx));
        }
        if (found == true) {
            const fz = try fuzz_list.addOne(allocator);
            fz.* = .{ .idx = i, .score = score };
        }
        std.mem.sort(Fuzz, fuzz_list.items, {}, lessThan);
    }
    return fuzz_list.toOwnedSlice(allocator);
}

const FuzzIterator = struct {
    sequence: []const u8,
    buffer: []const u8,
    index: usize = 0,

    pub fn next(fz: *FuzzIterator) ?usize {
        while (fz.index + fz.sequence.len <= fz.buffer.len) {
            const start = fz.index;
            const end = start + fz.sequence.len;
            defer fz.index += 1;
            if (std.ascii.eqlIgnoreCase(fz.buffer[start..end], fz.sequence)) return fz.index;
        }
        return null;
    }
};

test "fuzz-iter" {
    const test_str = "Hello mate";

    var iter = FuzzIterator{ .buffer = test_str, .sequence = "lo" };
    try std.testing.expectEqual(iter.next().?, 3);
    try std.testing.expectEqual(iter.next(), null);
    iter = FuzzIterator{ .buffer = test_str, .sequence = "he" };
    try std.testing.expectEqual(iter.next().?, 0);
    try std.testing.expectEqual(iter.next(), null);
    iter = FuzzIterator{ .buffer = test_str, .sequence = "e" };
    try std.testing.expectEqual(iter.next().?, 1);
    try std.testing.expectEqual(iter.next().?, 9);
    try std.testing.expectEqual(iter.next(), null);
    iter = FuzzIterator{ .buffer = test_str, .sequence = "x" };
    try std.testing.expectEqual(iter.next(), null);
}

test "fuzzer" {
    const test_list = [_][]const u8{ "eth remote", "eth set ip", "system eth", "adc info" };
    const allocator = std.testing.allocator;

    const fuzz_list = try fuzzList(&test_list, "eth", allocator);
    defer allocator.free(fuzz_list);

    try std.testing.expectEqual(Fuzz{ .idx = 0, .score = 3 }, fuzz_list[0]);

    try std.testing.expectEqual(Fuzz{ .idx = 1, .score = 3 }, fuzz_list[1]);

    try std.testing.expectEqual(Fuzz{ .idx = 2, .score = -4 }, fuzz_list[2]);

    try std.testing.expectEqual(fuzz_list.len, 3);
}
