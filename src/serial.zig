const std = @import("std");
const builtin = @import("builtin");
const utils = @import("serial");
const File = std.Io.File;
const Serial = @This();
const Stream = @import("stream.zig").Stream;
const Allocator = std.mem.Allocator;
port: File,
const Self = @This();

var options = Options{};

pub fn openStream(io: std.Io, allocator: Allocator, opts: Options) !Stream {
    const serial = try allocator.create(Self);
    errdefer allocator.destroy(serial);
    serial.* = .{
        .port = std.Io.Dir.openFileAbsolute(io, opts.port, .{ .mode = .read_write }) catch |err| return err,
    };

    try utils.configureSerialPort(serial.port, .{ .baud_rate = @intFromEnum(opts.baudrate), .parity = opts.parity, .stop_bits = opts.stopbits, .word_size = opts.wordsize });

    if (builtin.os.tag == .windows) {
        const COMMTIMEOUTS = extern struct {
            ReadIntervalTimeout: u32,
            ReadTotalTimeoutMultiplier: u32,
            ReadTotalTimeoutConstant: u32,
            WriteTotalTimeoutMultiplier: u32,
            WriteTotalTimeoutConstant: u32,
        };
        const SetCommTimeouts = @extern(*const fn (std.os.windows.HANDLE, *COMMTIMEOUTS) callconv(.winapi) i32, .{
            .name = "SetCommTimeouts",
            .library_name = "kernel32",
        });
        var timeouts: COMMTIMEOUTS = .{
            .ReadIntervalTimeout = 100,
            .ReadTotalTimeoutMultiplier = 0,
            .ReadTotalTimeoutConstant = 100,
            .WriteTotalTimeoutMultiplier = 0,
            .WriteTotalTimeoutConstant = 0,
        };
        _ = SetCommTimeouts(serial.port.handle, &timeouts);
    }

    options = opts;
    return .{
        .ctx = serial,
        .readFn = read,
        .writeFn = write,
        .closeFn = close,
        .statusFn = status,
    };
}

fn read(ctx: *anyopaque, io: std.Io, buf: []u8) !usize {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const list: []const []u8 = &.{buf};
    return try self.port.readStreaming(io, list);
}

fn write(ctx: *anyopaque, io: std.Io, buf: []const u8) !usize {
    const self: *Self = @ptrCast(@alignCast(ctx));
    _ = io;
    _ = self;
    _ = buf;
    return 0;
}

fn close(ctx: *anyopaque, io: std.Io, allocator: Allocator) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.port.close(io);
    allocator.destroy(self);
}

fn status(ctx: *anyopaque, allocator: Allocator) anyerror![]const u8 {
    _ = ctx;
    return try std.fmt.allocPrint(allocator, "Connected: {s} @ {d}", .{ options.port, @intFromEnum(options.baudrate) });
}

pub const Baudrates = enum(u32) {
    b115200 = 115200,
    b921600 = 921600,
    b9600 = 9600,
    b19200 = 19200,
    b38400 = 38400,
    b57600 = 57600,
    b230400 = 230400,
    b460800 = 460800,
};

pub const Options = struct {
    port: []const u8 = "",
    baudrate: Baudrates = .b115200,
    wordsize: utils.WordSize = .eight,
    parity: utils.Parity = .none,
    stopbits: utils.StopBits = .one,
};
