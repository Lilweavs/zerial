const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Tui = @import("tui.zig");
const Serial = @import("serial.zig");
const Logger = @import("log.zig");
const DropDown = @import("config_view.zig").DropDown;
const utils = @import("serial");

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

    // const tui = try allocator.create(DropDown);
    // const tui = try allocator.create(vxfw.ListView);

    // const data = try allocator.alloc(vxfw.Widget, 3);

    // data[0] = (vxfw.Text{ .text = try std.fmt.allocPrint(allocator, "hello", .{}) }).widget();
    // data[1] = (vxfw.Text{ .text = try std.fmt.allocPrint(allocator, "world", .{}) }).widget();
    // data[2] = (vxfw.Text{ .text = try std.fmt.allocPrint(allocator, "matey", .{}) }).widget();

    // tui.* = .{ .text = std.ArrayList(vxfw.Text).init(allocator), .list = .{ .children = .{ .builder = .{ .userdata = tui, .buildFn = DropDown.widgetBuilder } } } };
    // tui.* = .{ .text = std.ArrayList(vxfw.Text).init(allocator) };

    // try tui.text.append(vxfw.Text{ .text = "hello" });
    // try tui.text.append(vxfw.Text{ .text = "world" });
    // try tui.text.append(vxfw.Text{ .text = "matey" });

    // tui.* = .{
    //     .children = .{ .slice = data },
    // };

    const tui = try allocator.create(Tui.Tui);
    defer allocator.destroy(tui);
    defer tui.deinit();

    try logger.log("Hello, World!\n", .{});

    var available_ports = try utils.list();

    while (try available_ports.next()) |port| {
        try logger.log("{s}\n  {s}\n", .{ port.file_name, port.display_name });
    }

    // zig fmt: off
    tui.* = .{
        .allocator = allocator,
        .serial = .{
            .allocator = allocator,
        },
        .send_view = .{
            .input = .{
                .buf = vxfw.TextField.Buffer.init(allocator),
                .unicode = &app.vx.unicode,
                .onSubmit = @import("send_view.zig").SendView.onSubmit,
                .userdata = tui
            }
        },
        .serial_monitor = .{
            .data = try @import("circular_array.zig").CircularArray(@import("serial_monitor.zig").Record).initCapacity(allocator, 1024),
            .hex_data = try @import("circular_array.zig").CircularArray(@import("serial_monitor.zig").Record).initCapacity(allocator, 1024),
            .allocator = allocator,
        },
        .configuration_view = .{
            .allocator = allocator,
            .port_dropdown = .{
                .list = std.ArrayList(vxfw.Text).empty
            },
            .baudrate_dropdown = .{
                .list = std.ArrayList(vxfw.Text).empty
            },
            .databits_dropdown = .{
                .list = std.ArrayList(vxfw.Text).empty
            },
            .parity_dropdown = .{
                .list = std.ArrayList(vxfw.Text).empty
            },
            .stopbits_dropdown = .{
                .list = std.ArrayList(vxfw.Text).empty
            },
            .ip_dropdown= .{
                .list = std.ArrayList(vxfw.Text).empty
            },
            .userdata = tui,
            .input = .{
                .buf = vxfw.TextField.Buffer.init(allocator),
                .unicode = &app.vx.unicode,
                .userdata = tui
            },
        }
    };
    // zig fmt: on

    // all views that are not the default should not be statically allocated

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
}

test "Tui" {
    _ = @import("tui.zig");
}
