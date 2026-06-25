const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Tui = @import("tui.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var tty_buffer: [1024 * 8]u8 = undefined;
    var app: vxfw.App = try .init(io, allocator, init.environ_map, &tty_buffer);
    defer app.deinit();

    const tui = try allocator.create(Tui.Tui);
    try tui.init(io, allocator);

    defer allocator.destroy(tui);
    defer tui.deinit();

    try app.run(tui.widget(), .{});
}

test "Tui" {
    _ = @import("tui.zig");
}
