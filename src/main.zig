const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Tui = @import("tui.zig");
const Allocator = std.mem.Allocator;

fn resolveAppdataDir(allocator: Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("XDG_DATA_HOME")) |xdg| {
        return try std.fs.path.join(allocator, &.{ xdg, "zerial" });
    }
    const home = environ.get("HOME") orelse return error.AppdataDirNotFound;
    return try std.fs.path.join(allocator, &.{ home, ".local", "share", "zerial" });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var tty_buffer: [1024 * 8]u8 = undefined;
    var app: vxfw.App = try .init(io, allocator, init.environ_map, &tty_buffer);
    defer app.deinit();

    const appdata_dir = try resolveAppdataDir(allocator, init.environ_map);
    defer allocator.free(appdata_dir);

    const tui = try allocator.create(Tui.Tui);
    try tui.init(io, allocator, appdata_dir);

    defer allocator.destroy(tui);
    defer tui.deinit();

    try app.run(tui.widget(), .{});
}

test "Tui" {
    _ = @import("tui.zig");
}
