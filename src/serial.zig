const std = @import("std");
const builtin = @import("builtin");
const utils = @import("serial");
const File = std.Io.File;
const Serial = @This();
const Stream = @import("tui.zig").Stream;
const Allocator = std.mem.Allocator;
// is_open: bool = false,
// mutex: std.Thread.Mutex = .{},

// config: Options = .{},

port: File,
// fh: std.Io.File.Handle,
const Self = @This();

var options = Options{};

pub fn openStream(io: std.Io, allocator: Allocator, opts: Options) !Stream {
    const serial = try allocator.create(Self);
    errdefer allocator.destroy(serial);
    serial.* = .{
        .port = std.Io.Dir.openFileAbsolute(io, opts.port, .{ .mode = .read_write }) catch |err| return err,
    };

    try utils.configureSerialPort(serial.port, .{ .baud_rate = @intFromEnum(opts.baudrate), .parity = opts.parity, .stop_bits = opts.stopbits, .word_size = opts.wordsize });
    options = opts;
    return .{
        .ctx = serial,
        .readFn = read,
        .writeFn = write,
        .closeFn = close,
        .statusFn = status,
    };
}

// pub fn stream(self: *Self) Stream {
//     return .{
//         .ctx = self,
//         .readFn = read,
//         .writeFn = write,
//     };
// }

fn read(ctx: *anyopaque, io: std.Io, buf: []u8) !usize {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const list: []const []u8 = &.{buf};
    // var reader = self.port.readerStreaming(io, buf);
    // const b = try reader.interface.takeByte();
    // buf[0] = b;
    // return 1;
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

// pub fn getReaderInterface(self: *Serial) ?*std.Io.Reader {
//     return if (self.reader) |*reader| &reader.interface else null;
// }

// pub fn getWriterInterface(self: *Serial) ?*std.Io.Writer {
//     return if (self.writer) |*writer| &writer.interface else null;
// }

// pub fn getStatus(self: Serial, allocator: std.mem.Allocator) ![]const u8 {
//     return if (self.is_open)
//         try std.fmt.allocPrint(allocator, "SERIAL | Connected: {s} @ {d} {d}{c}{d}", .{
//             self.config.port,
//             @intFromEnum(self.config.baudrate),
//             @intFromEnum(self.config.wordsize),
//             @intFromEnum(self.config.parity),
//             @intFromEnum(self.config.stopbits),
//         })
//     else
//         try std.fmt.allocPrint(allocator, "SERIAL | Disonnected | Error: {t}", .{
//             self.error_code,
//         });
// }

pub fn openWithConfiguration(self: *Serial, opts: Options) !void {
    if (self.is_open) {
        self.close();
    }

    var cfg = opts;

    errdefer |err| {
        self.error_code = err;
    }

    cfg.port = try std.fmt.bufPrint(&self.port_buffer, if (builtin.os.tag == .windows) "\\\\.\\{s}" else "{s}", .{cfg.port});

    self.file = try std.fs.cwd().openFile(cfg.port, .{ .mode = .read_write });

    utils.configureSerialPort(self.file.?, .{ .baud_rate = @intFromEnum(cfg.baudrate), .parity = cfg.parity, .stop_bits = cfg.stopbits, .word_size = cfg.wordsize }) catch {
        self.error_code = error.CannotConfigureSerialPort;
        self.close();
    };

    if (builtin.os.tag == .windows) {
        var timeouts: COMMTIMEOUTS = undefined;
        if (GetCommTimeouts(self.file.?.handle, &timeouts) == 0) {
            // @import("main.zig").logger.log("GetLastError: {d}\n", .{std.os.windows.kernel32.GetLastError()}) catch {};
        } else {
            // @import("main.zig").logger.log("[ SUCCESS ]: GetCommTimeouts\n", .{}) catch {};
        }

        timeouts.read_interval_timeout = std.math.maxInt(std.os.windows.DWORD);
        timeouts.read_total_timeout_multiplier = std.math.maxInt(std.os.windows.DWORD);
        timeouts.read_total_timeout_constant = 1;
        timeouts.write_total_timeout_multiplier = 0;
        timeouts.write_total_timeout_constant = 0;

        if (SetCommTimeouts(self.file.?.handle, &timeouts) == 0) {
            // @import("main.zig").logger.log("GetLastError: {}\n", .{std.os.windows.kernel32.GetLastError()}) catch {};
        } else {
            // @import("main.zig").logger.log("[ SUCCESS ]: SetCommTimeouts\n", .{}) catch {};
        }
    }

    self.config = cfg;
    self.reader = self.file.?.readerStreaming(&.{});
    self.writer = self.file.?.writerStreaming(&.{});
    self.is_open = true;
    self.error_code = error.None;
}

const COMMTIMEOUTS = extern struct {
    read_interval_timeout: std.os.windows.DWORD,
    read_total_timeout_multiplier: std.os.windows.DWORD,
    read_total_timeout_constant: std.os.windows.DWORD,
    write_total_timeout_multiplier: std.os.windows.DWORD,
    write_total_timeout_constant: std.os.windows.DWORD,
};

extern "kernel32" fn SetCommTimeouts(hFile: std.os.windows.HANDLE, lpCommTimeouts: *COMMTIMEOUTS) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetCommTimeouts(hFile: std.os.windows.HANDLE, lpCommTimeouts: *COMMTIMEOUTS) callconv(.winapi) std.os.windows.BOOL;

pub fn setPortTimeout(port: std.fs.File, readTimeout: u32, writeTimeout: u32) !void {
    var userTimeoutConfiguration = COMMTIMEOUTS{ .ReadIntervalTimeout = readTimeout, .ReadTotalTimeoutConstant = readTimeout, .ReadTotalTimeoutMultiplier = 1, .WriteTotalTimeoutConstant = writeTimeout, .WriteTotalTimeoutMultiplier = 1 };
    _ = SetCommTimeouts(port.handle, &userTimeoutConfiguration);
}

pub fn deinit(self: *Serial) void {
    self.close();
}

// pub fn close(self: *Serial) void {
//     if (self.file) |ptr| {
//         self.is_open = false;
//         ptr.close();
//     }
//     self.is_open = false;
// }
