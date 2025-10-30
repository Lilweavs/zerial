const std = @import("std");
const builtin = @import("builtin");
const net = std.net;

const NetStream = @This();

mutex: std.Thread.Mutex = .{},

stream: std.net.Stream = undefined,
reader: std.net.Stream.Reader = undefined,
writer: std.net.Stream.Writer = undefined,

is_open: bool = false,

mode: NetMode = .TCP,
addr: std.net.Address = .initIp4(.{ 127, 0, 0, 1 }, 65432),

error_code: anyerror = error.None,

pub const NetMode = enum {
    TCP,
    UDP,
};

pub fn getStatus(self: *NetStream, allocator: std.mem.Allocator) ![]const u8 {
    return if (self.is_open) try std.fmt.allocPrint(allocator, "{s} | Connected: {f}", .{
        @tagName(self.mode),
        self.addr,
    }) else try std.fmt.allocPrint(allocator, "SERIAL | Disonnected | Error: {t}", .{self.error_code});
}

pub fn connect(self: *NetStream, addr: std.net.Address, mode: NetMode) !void {
    self.mode = mode;
    self.addr = addr;
    errdefer |err| {
        self.error_code = err;
    }

    self.stream = if (mode == .TCP)
        .{ .handle = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) }
    else
        .{ .handle = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP) };

    try std.posix.connect(self.stream.handle, &addr.any, addr.getOsSockLen());
    self.reader = self.stream.reader(&.{});
    self.writer = self.stream.writer(&.{});
    self.is_open = true;
}

pub fn close(self: *NetStream) void {
    self.stream.close();
    self.is_open = false;
}

pub fn getReaderInterface(self: *NetStream) *std.io.Reader {
    return self.reader.interface();
}

pub fn getWriterInterface(self: *NetStream) *std.io.Writer {
    return &self.writer.interface;
}
