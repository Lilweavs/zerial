const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Tui = @import("tui.zig");
const Serial = @import("serial.zig");
const Logger = @import("log.zig");
const DropDown = @import("config_view.zig").DropDown;
const utils = @import("serial");
const builtin = @import("builtin");
const zon = @import("build.zig.zon");

var buffer: [1024 * 4]u8 = undefined;

var global_term: ?std.process.Child.Term = null;

pub var logger: Logger = .{};

pub fn main() !void {
    try logger.init();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var app = try vxfw.App.init(gpa.allocator());
    errdefer app.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tui = try allocator.create(Tui.Tui);
    defer allocator.destroy(tui);
    defer tui.deinit();

    tui.* = .{
        .allocator = allocator,
        .serial = .{},
        .net = .{},
        .send_view = .{
            .input = .{
                .buf = vxfw.TextField.Buffer.init(allocator),
                .unicode = &app.vx.unicode,
                .onSubmit = @import("send_view.zig").SendView.onSubmit,
                .userdata = &tui.send_view,
            },
            .history_list = .{
                .list = std.ArrayList(vxfw.Text).empty,
            },
            .write_queue = &tui.write_queue,
        },
        .serial_monitor = .{
            .data = try @import("circular_array.zig").CircularArray(@import("serial_monitor.zig").Record).initCapacity(allocator, 2048),
            .hex_data = try @import("circular_array.zig").CircularArray(@import("serial_monitor.zig").Record).initCapacity(allocator, 2048),
            .allocator = allocator,
        },
        .configuration_view = .{
            .allocator = allocator,
            .port_dropdown = .{ .list = std.ArrayList(vxfw.Text).empty },
            .baudrate_dropdown = .{ .list = std.ArrayList(vxfw.Text).empty },
            .databits_dropdown = .{ .list = std.ArrayList(vxfw.Text).empty },
            .parity_dropdown = .{ .list = std.ArrayList(vxfw.Text).empty },
            .stopbits_dropdown = .{ .list = std.ArrayList(vxfw.Text).empty },
            .ip_dropdown = .{ .list = std.ArrayList(vxfw.Text).empty },
            .net_mode_dropdown = .{ .list = std.ArrayList(vxfw.Text).empty },
            .userdata = tui,
            .input = .{
                .buf = vxfw.TextField.Buffer.init(allocator),
                .unicode = &app.vx.unicode,
                .userdata = tui,
            },
        },
    };

    const zerial_dir = try std.fs.getAppDataDir(allocator, @tagName(zon.name));
    defer allocator.free(zerial_dir);

    try std.fs.cwd().makePath(zerial_dir);

    const file_history = try std.fs.path.join(allocator, &.{
        zerial_dir,
        "history.txt",
    });
    defer allocator.free(file_history);

    var buf: [1024]u8 = undefined;
    if (std.fs.cwd().openFile(file_history, .{ .mode = .read_only })) |file| {
        defer file.close();
        var file_reader = file.reader(&buf);
        const reader = &file_reader.interface;

        while (reader.takeDelimiterExclusive('\n')) |line| {
            try tui.*.send_view.history_list.list.append(allocator, .{ .text = try allocator.dupe(u8, line) });
        } else |err| switch (err) {
            error.EndOfStream => {},
            error.StreamTooLong,
            error.ReadFailed,
            => |e| return e,
        }
    } else |err| switch (err) {
        error.FileNotFound => {
            const f = try std.fs.cwd().createFile(file_history, .{});
            f.close();
        },
        else => return err,
    }

    try app.run(tui.widget(), .{});
    defer app.deinit();
    if (global_term) |term| {
        switch (term) {
            .Exited => |code| {
                if (code > 0)
                    std.log.err("error: {d}", .{code});
                return;
            },
            else => {},
        }
    }

    var file = try std.fs.cwd().createFile(file_history, .{});
    defer file.close();
    var file_writer = file.writer(&.{});
    var writer = &file_writer.interface;

    for (tui.send_view.history_list.list.items) |item| {
        try writer.writeAll(item.text);
        try writer.writeByte('\n');
    }
}

test "Tui" {
    _ = @import("tui.zig");
}
