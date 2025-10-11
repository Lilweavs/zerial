const std = @import("std");
const builtin = @import("builtin");
const utils = @import("serial");
const File = std.fs.File;
const Serial = @This();
const Allocator = std.mem.Allocator;

file: ?File = null,
is_open: bool = false,
mutex: std.Thread.Mutex = .{},
allocator: Allocator,

reader: ?File.Reader = null,
writer: ?File.Writer = null,

rx_buffer: [4096]u8 = undefined,
tx_buffer: [4096]u8 = undefined,

bps: usize = 0,

config: Options = .{},
baudrate: u32 = 115200,
port: ?[]const u8 = null,

pub fn init(self: *Serial) !void {
    _ = self;
}

pub fn open(self: *Serial, port: []const u8, baudrate: u32) anyerror!void {
    return try self.openWithConfiguration(port, .{
        .baudrate = @enumFromInt(baudrate),
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

pub fn openWithConfiguration(self: *Serial, opts: Options) anyerror!void {
    self.config = opts;
    if (self.is_open) {
        self.close();
    }

    if (builtin.os.tag == .windows) {
        const full_port_name = try std.fmt.allocPrint(self.allocator, "\\\\.\\{s}", .{opts.port});
        defer self.allocator.free(full_port_name);
        self.file = try std.fs.cwd().openFile(full_port_name, .{ .mode = .read_write });
    } else {
        self.file = try std.fs.cwd().openFile(opts.port, .{ .mode = .read_write });
    }

    try utils.configureSerialPort(self.file.?, .{ .baud_rate = @intFromEnum(opts.baudrate), .parity = opts.parity, .stop_bits = opts.stopbits, .word_size = opts.wordsize });

    self.baudrate = @intFromEnum(opts.baudrate);

    // free port memory before assigning new port name
    if (self.port) |port_name| {
        self.allocator.free(port_name);
    }
    self.port = try self.allocator.dupe(u8, opts.port);

    if (builtin.os.tag == .windows) {
        var timeouts: COMMTIMEOUTS = undefined;
        // var timeouts = COMMTIMEOUTS{
        //     .read_interval_timeout = 1,
        //     .read_total_timeout_multiplier = 1,
        //     .read_total_timeout_constant = 1,
        //     .write_total_timeout_multiplier = 1,
        //     .write_total_timeout_constant = 10,
        // };
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

    self.reader = self.file.?.readerStreaming(&self.rx_buffer);
    self.writer = self.file.?.writerStreaming(&self.tx_buffer);

    self.is_open = true;
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
    if (self.port) |port_name| {
        self.allocator.free(port_name);
    }
}

pub fn close(self: *Serial) void {
    if (self.file) |ptr| {
        self.is_open = false;
        ptr.close();
    }
    self.is_open = false;
}

pub fn readToBuffer(self: *Serial, buffer: []u8) anyerror!usize {
    var bytes_read: usize = 0;
    if (self.reader) |*reader| {
        // self.mutex.lock();
        // defer self.mutex.unlock();

        // while (bytes_read < buffer.len) {
        bytes_read += try reader.read(buffer);
        // @import("main.zig").logger.log("Bytes Read: {d}\n", .{bytes_read}) catch {};

        // if (file.reader().readByte()) |byte| {
        // buffer[bytes_read] = byte;
        // } else |_| {
        // break;
        // }
    }
    return bytes_read;
}

// fn read(self: *Serial) anyerror!usize {
//     if (self.file) |file| {
//         if (file.reader().readByte()) |byte| {
//             self.mutex.lock();
//             defer self.mutex.unlock();
//             self.buffer[self.len] = byte;
//             self.len += 1;
//             return 1;
//         } else |_| {
//             // std.debug.print("Error reading from serial port: {any}", .{err});
//         }
//     }
//     return 0;
// }

pub fn write(self: *Serial, to_send: []const u8) anyerror!void {
    self.mutex.lock();
    defer self.mutex.unlock();
    _ = try self.file.?.write(to_send);
}

pub fn copyBytesDiscard(self: *Serial, buffer: []u8) usize {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.buffer.len == 0) return 0;

    const bytes_copied = self.len;

    @memcpy(buffer[0..self.len], self.buffer[0..self.len]);
    self.len = 0;

    return bytes_copied;
}

// fn readerThread(self: *Serial) anyerror!void {
//     var prev_time = std.time.milliTimestamp();
//     var bytes_sent: usize = 0;
//     while (self.is_open) {
//         // if (self.file.?.metadata()) |metadata| {
//         //     const size = metadata.size();
//         //     std.debug.print("Bytes: {d}\n", .{size});
//         // } else |_| {}
//         bytes_sent += try self.read();

//         if (std.time.milliTimestamp() - prev_time > std.time.ms_per_s * 1) {
//             self.bps = bytes_sent * 10;
//             prev_time = std.time.milliTimestamp();
//             bytes_sent = 0;
//         }
//     }
// }
