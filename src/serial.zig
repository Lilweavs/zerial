const std = @import("std");
const builtin = @import("builtin");
const utils = @import("serial");
const File = std.fs.File;
const Serial = @This();

file: ?File = null,
is_open: bool = false,
mutex: std.Thread.Mutex = .{},

reader: ?File.Reader = null,
writer: ?File.Writer = null,

config: Options = .{},
port_buffer: [256]u8 = undefined,

error_code: ?anyerror = null,

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

pub fn getReaderInterface(self: *Serial) ?*std.Io.Reader {
    return if (self.reader) |*reader| &reader.interface else null;
}

pub fn getWriterInterface(self: *Serial) ?*std.Io.Writer {
    return if (self.writer) |*writer| &writer.interface else null;
}

pub fn openWithConfiguration(self: *Serial, opts: Options) !bool {
    if (self.is_open) {
        self.close();
    }

    var cfg = opts;

    cfg.port = try std.fmt.bufPrint(&self.port_buffer, if (builtin.os.tag == .windows) "\\\\.\\{s}" else "{s}", .{cfg.port});

    self.file = std.fs.cwd().openFile(cfg.port, .{ .mode = .read_write }) catch |err| {
        self.error_code = err;
        return true;
    };

    utils.configureSerialPort(self.file.?, .{ .baud_rate = @intFromEnum(cfg.baudrate), .parity = cfg.parity, .stop_bits = cfg.stopbits, .word_size = cfg.wordsize }) catch {
        self.error_code = error.CannotConfigureSerialPort;
        self.close();
        return true;
    };

    if (builtin.os.tag == .windows) {
        var timeouts: COMMTIMEOUTS = undefined;
        if (GetCommTimeouts(self.file.?.handle, &timeouts) == 0) {
            @import("main.zig").logger.log("GetLastError: {d}\n", .{std.os.windows.kernel32.GetLastError()}) catch {};
        } else {
            @import("main.zig").logger.log("[ SUCCESS ]: GetCommTimeouts\n", .{}) catch {};
        }

        timeouts.read_interval_timeout = std.math.maxInt(std.os.windows.DWORD);
        timeouts.read_total_timeout_multiplier = std.math.maxInt(std.os.windows.DWORD);
        timeouts.read_total_timeout_constant = 1;
        timeouts.write_total_timeout_multiplier = 0;
        timeouts.write_total_timeout_constant = 0;

        if (SetCommTimeouts(self.file.?.handle, &timeouts) == 0) {
            @import("main.zig").logger.log("GetLastError: {}\n", .{std.os.windows.kernel32.GetLastError()}) catch {};
        } else {
            @import("main.zig").logger.log("[ SUCCESS ]: SetCommTimeouts\n", .{}) catch {};
        }
    }

    self.config = cfg;
    self.reader = self.file.?.readerStreaming(&.{});
    self.writer = self.file.?.writerStreaming(&.{});
    self.is_open = true;
    self.error_code = null;
    return false;
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

pub fn close(self: *Serial) void {
    if (self.file) |ptr| {
        self.is_open = false;
        ptr.close();
    }
    self.is_open = false;
}
