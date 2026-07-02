const std = @import("std");
const builtin = @import("builtin");
const utils = @import("serial");
const File = std.Io.File;
const Serial = @This();
const Stream = @import("stream.zig").Stream;
const Allocator = std.mem.Allocator;
port: File,
io: std.Io,
rx_bytes: u64 = 0,
rx_prev: u64 = 0,
bw_time: i64 = 0,
bw_rate: u64 = 0,
const Self = @This();

var options = Options{};
var port_name: ?[]u8 = null;

pub fn openStream(io: std.Io, allocator: Allocator, opts: Options) !Stream {
    const serial = try allocator.create(Self);
    errdefer allocator.destroy(serial);

    const port_path = if (builtin.os.tag == .windows and
        opts.port.len > 0 and
        !std.mem.startsWith(u8, opts.port, "\\\\.\\") and
        !std.mem.startsWith(u8, opts.port, "/"))
        try std.fmt.allocPrint(allocator, "\\\\.\\{s}", .{opts.port})
    else
        try allocator.dupe(u8, opts.port);
    defer allocator.free(port_path);

    serial.* = .{
        .port = std.Io.Dir.openFileAbsolute(io, port_path, .{ .mode = .read_write }) catch |err| return err,
        .io = io,
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

    const new_port = try allocator.dupe(u8, opts.port);
    if (port_name) |p| allocator.free(p);
    port_name = new_port;
    options = opts;
    options.port = port_name.?;
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
    const n = try self.port.readStreaming(io, list);
    self.rx_bytes += n;
    return n;
}

fn write(ctx: *anyopaque, io: std.Io, buf: []const u8) !usize {
    const self: *Self = @ptrCast(@alignCast(ctx));
    try self.port.writeStreamingAll(io, buf);
    return buf.len;
}

fn close(ctx: *anyopaque, io: std.Io, allocator: Allocator) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.port.close(io);
    allocator.destroy(self);
    if (port_name) |p| {
        allocator.free(p);
        port_name = null;
    }
}

fn status(ctx: *anyopaque, allocator: Allocator) anyerror![]const u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
    const elapsed = now - self.bw_time;
    if (elapsed >= 1000) {
        self.bw_rate = self.rx_bytes - self.rx_prev;
        self.rx_prev = self.rx_bytes;
        self.bw_time = now;
    }
    const bw_str = if (self.bw_rate >= 1_000_000)
        try std.fmt.allocPrint(allocator, "{d:.1}MB/s", .{@as(f64, @floatFromInt(self.bw_rate)) / 1_000_000})
    else if (self.bw_rate >= 1_000)
        try std.fmt.allocPrint(allocator, "{d:.1}KB/s", .{@as(f64, @floatFromInt(self.bw_rate)) / 1_000})
    else
        try std.fmt.allocPrint(allocator, "{}B/s", .{self.bw_rate});
    defer allocator.free(bw_str);

    return try std.fmt.allocPrint(allocator, "Connected: {s} @ {d}  BW: {s}", .{
        options.port, @intFromEnum(options.baudrate), bw_str,
    });
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
