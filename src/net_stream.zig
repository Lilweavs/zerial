const std = @import("std");
const builtin = @import("builtin");
const net = std.net;

const NetStream = @This();

mutex: std.Thread.Mutex = .{},

stream: std.net.Stream = undefined,
reader: std.net.Stream.Reader = undefined,
writer: std.net.Stream.Writer = undefined,

is_open: bool = false,

pub const NetMode = enum {
    Tcp,
    Udp,
};

pub fn connect(nw: *NetStream, ip_address: []const u8, port: u16, mode: NetMode) !void {
    const addr = try std.net.Address.parseIp(ip_address, port);

    if (mode == .Tcp) {
        nw.stream = .{
            .handle = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP),
        };
    } else {
        nw.stream = .{
            .handle = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP),
        };
    }

    try std.posix.connect(nw.socket, &addr.any, addr.getOsSockLen());
    nw.reader = nw.stream.reader(&.{});
    nw.writer = nw.stream.writer(&.{});
    nw.is_open = true;
}

pub fn close(nw: *NetStream) void {
    nw.stream.close();
    nw.is_open = false;
}

pub fn getReaderInterface(nw: *NetStream) *std.io.Reader {
    return nw.reader.interface();
}

pub fn getWriterInterface(nw: *NetStream) *std.io.Writer {
    return nw.writer.interface();
}
