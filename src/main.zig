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
const clap = @import("clap");

var buffer: [1024 * 4]u8 = undefined;

var global_term: ?std.process.Child.Term = null;

pub var logger: Logger = .{};

pub fn main() !void {
    try logger.init();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display help and exit.
        \\-s, --serial <str>       Connect to a serial port [port:baud] or [port]
        \\-t, --tcp <str>          Connect to a tcp address [X.X.X.X:port]
        \\-u, --udp <str>          Connect to a UDP address [X.X.X.X:port]
    );

    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .allocator = allocator }) catch |err| {
        return err;
    };

    defer res.deinit();

    var stdout_file = std.fs.File.stderr().writer(&.{});

    if (res.args.help != 0) {
        const writer = &stdout_file.interface;
        try clap.help(writer, clap.Help, &params, .{});
        return;
    }
    var cli = false;
    var scfg: ?Serial.Options = null;
    if (res.args.serial) |ser| {
        scfg = .{};
        var iter = std.mem.tokenizeScalar(u8, ser, ':');

        scfg.?.port = iter.next().?;
        const baud: u32 = std.fmt.parseInt(u32, iter.next() orelse "115200", 10) catch return error.InvalidBaudrate;
        scfg.?.baudrate = std.enums.fromInt(Serial.Baudrates, baud) orelse return error.InvalidBaudrate;
        cli = true;
    }

    var addr: ?std.net.Address = null;
    if (res.args.tcp) |tcp_addr| {
        addr = try std.net.Address.parseIpAndPort(tcp_addr);
        cli = true;
    }
    if (res.args.udp) |udp_addr| {
        addr = try std.net.Address.parseIpAndPort(udp_addr);
        cli = true;
    }

    var app = try vxfw.App.init(gpa.allocator());
    errdefer app.deinit();
    defer app.deinit();

    const tui = try allocator.create(Tui.Tui);
    defer allocator.destroy(tui);
    defer tui.deinit();

    tui.* = .{
        .allocator = allocator,
        .cli = cli,
        .serial = .{
            .config = scfg orelse .{},
        },
        .net = .{
            .addr = addr,
            .mode = if (res.args.udp != null) .UDP else .TCP,
        },
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
