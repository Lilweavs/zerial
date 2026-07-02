const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Tui = @import("tui.zig");
const Serial = @import("serial.zig");
const ser_utils = @import("serial");
const Allocator = std.mem.Allocator;

fn resolveAppdataDir(allocator: Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (builtin.os.tag == .windows) {
        const localappdata = environ.get("LOCALAPPDATA") orelse return error.AppdataDirNotFound;
        return try std.fs.path.join(allocator, &.{ localappdata, "zerial" });
    } else {
        if (environ.get("XDG_DATA_HOME")) |xdg| {
            return try std.fs.path.join(allocator, &.{ xdg, "zerial" });
        }
        const home = environ.get("HOME") orelse return error.AppdataDirNotFound;
        return try std.fs.path.join(allocator, &.{ home, ".local", "share", "zerial" });
    }
}

fn parseArgs(args_vec: []const [:0]const u8) Serial.Options {
    var opts = Serial.Options{};
    var i: usize = 1;
    while (i < args_vec.len) : (i += 1) {
        const arg = args_vec[i];
        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args_vec.len) @panic("--port requires a value");
            opts.port = args_vec[i];
        } else if (std.mem.eql(u8, arg, "--baud")) {
            i += 1;
            if (i >= args_vec.len) @panic("--baud requires a value");
            const val = args_vec[i];
            var found = false;
            inline for (std.meta.fields(Serial.Baudrates)) |field| {
                if (std.mem.eql(u8, field.name[1..], val)) {
                    opts.baudrate = @enumFromInt(field.value);
                    found = true;
                }
            }
            if (!found) @panic("invalid baud rate");
        } else if (std.mem.eql(u8, arg, "--databits")) {
            i += 1;
            if (i >= args_vec.len) @panic("--databits requires a value");
            opts.wordsize = std.meta.stringToEnum(ser_utils.WordSize, args_vec[i]) orelse @panic("invalid databits");
        } else if (std.mem.eql(u8, arg, "--parity")) {
            i += 1;
            if (i >= args_vec.len) @panic("--parity requires a value");
            opts.parity = std.meta.stringToEnum(ser_utils.Parity, args_vec[i]) orelse @panic("invalid parity");
        } else if (std.mem.eql(u8, arg, "--stopbits")) {
            i += 1;
            if (i >= args_vec.len) @panic("--stopbits requires a value");
            opts.stopbits = std.meta.stringToEnum(ser_utils.StopBits, args_vec[i]) orelse @panic("invalid stopbits");
        } else {
            std.log.err("usage: zerial [--port <path>] [--baud <rate>] [--databits <5|6|7|8>] [--parity <none|odd|even|mark|space>] [--stopbits <1|1.5|2>]", .{});
            std.process.exit(1);
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    const serial_opts = if (args.len > 1) parseArgs(args) else Serial.Options{};

    var tty_buffer: [1024 * 8]u8 = undefined;
    var app: vxfw.App = try .init(io, allocator, init.environ_map, &tty_buffer);
    defer app.deinit();

    const appdata_dir = try resolveAppdataDir(allocator, init.environ_map);
    defer allocator.free(appdata_dir);

    const tui = try allocator.create(Tui.Tui);
    try tui.init(io, allocator, appdata_dir, serial_opts);

    defer allocator.destroy(tui);
    defer tui.deinit();

    try app.run(tui.widget(), .{});
}
