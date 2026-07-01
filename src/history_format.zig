const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn escapeForFile(s: []const u8, allocator: Allocator) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n') == null and std.mem.indexOfScalar(u8, s, '\\') == null) {
        return try allocator.dupe(u8, s);
    }
    var result = try std.ArrayList(u8).initCapacity(allocator, s.len * 2);
    for (s) |c| {
        switch (c) {
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            else => try result.append(allocator, c),
        }
    }
    return try result.toOwnedSlice(allocator);
}

pub fn unescapeFromFile(s: []const u8, allocator: Allocator) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) {
        return try allocator.dupe(u8, s);
    }
    var result = try std.ArrayList(u8).initCapacity(allocator, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                '\\' => try result.append(allocator, '\\'),
                'n' => try result.append(allocator, '\n'),
                else => {
                    try result.append(allocator, s[i]);
                    try result.append(allocator, s[i + 1]);
                },
            }
            i += 2;
        } else {
            try result.append(allocator, s[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice(allocator);
}
