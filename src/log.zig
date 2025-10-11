const std = @import("std");

const net = std.net;
const Logger = @This();

stream: std.net.Stream = undefined,

buffer: [4096]u8 = undefined,

pub fn write(logger: *Logger, bytes: []u8) void {
    // var writer = logger.stream.writer();
    // writer.writeAll(bytes) catch {};
    _ = logger.stream.writeAll(bytes) catch {};
}

pub fn log(logger: *Logger, comptime format: []const u8, args: anytype) !void {
    var writer = logger.stream.writer(&logger.buffer);

    try writer.interface.print(format, args);
    try writer.interface.flush();
}

pub fn init(
    logger: *Logger,
) !void {
    const addr = try std.net.Address.parseIp("127.0.0.1", 54321);

    // const handle = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);

    logger.stream = .{
        .handle = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP),
    };
    try std.posix.connect(logger.stream.handle, &addr.any, addr.getOsSockLen());

    // logger.stream = try net.tcpConnectToAddress(addr);

    // return Logger{
    //     .stream = try net.tcpConnectToAddress(try std.net.Address.parseIp("127.0.0.1", 54321)),
    // };

    // const addr = try std.net.Address.parseIp("127.0.0.1", 54321);

    // logger.stream = try net.tcpConnectToAddress(addr);
}

pub fn deinit(logger: *Logger) void {
    logger.stream.close();
}
