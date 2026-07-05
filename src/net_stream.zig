const std = @import("std");
const Stream = @import("stream.zig").Stream;
const Allocator = std.mem.Allocator;

const net = std.Io.net;

pub const NetMode = enum {
    TCP,
    UDP,
};

const NetStream = struct {
    socket: net.Socket,
    mode: NetMode,
    io: std.Io,
    host: []const u8,
    port: u16,
    rx_bytes: u64 = 0,
    rx_prev: u64 = 0,
    bw_time: i64 = 0,
    bw_rate: u64 = 0,
};

pub fn openStream(io: std.Io, allocator: Allocator, host: []const u8, port: u16, mode: NetMode) !Stream {
    const self = try allocator.create(NetStream);
    errdefer allocator.destroy(self);

    const host_duped = try allocator.dupe(u8, host);
    errdefer allocator.free(host_duped);

    const socket = switch (mode) {
        .TCP => blk: {
            const host_name = try net.HostName.init(host);
            const stream = try host_name.connect(io, port, .{ .mode = .stream, .protocol = .tcp });
            break :blk stream.socket;
        },
        .UDP => blk: {
            const resolved_addr = net.IpAddress.parseLiteral(host) catch {
                const host_name = try net.HostName.init(host);
                var lookup_buf: [32]net.HostName.LookupResult = undefined;
                var queue: std.Io.Queue(net.HostName.LookupResult) = .init(&lookup_buf);
                try host_name.lookup(io, &queue, .{ .port = port });
                const result = queue.getOne(io) catch |e| switch (e) {
                    error.Closed => return error.UnknownHostName,
                    else => |err| return err,
                };
                break :blk switch (result) {
                    .address => |a| try io.vtable.netConnectIp(io.userdata, &a, .{ .mode = .dgram, .protocol = .udp }),
                    else => return error.UnknownHostName,
                };
            };
            break :blk try io.vtable.netConnectIp(io.userdata, &resolved_addr, .{ .mode = .dgram, .protocol = .udp });
        },
    };

    self.* = .{
        .socket = socket,
        .mode = mode,
        .io = io,
        .host = host_duped,
        .port = port,
    };

    return .{
        .ctx = self,
        .readFn = read,
        .writeFn = write,
        .closeFn = close,
        .statusFn = status,
    };
}

fn read(ctx: *anyopaque, io: std.Io, buf: []u8) anyerror!usize {
    const self: *NetStream = @ptrCast(@alignCast(ctx));
    var buf_list = [_][]u8{buf};
    const n = try io.vtable.netRead(io.userdata, self.socket.handle, &buf_list);
    self.rx_bytes += n;
    return n;
}

fn write(ctx: *anyopaque, io: std.Io, buf: []const u8) anyerror!usize {
    const self: *NetStream = @ptrCast(@alignCast(ctx));
    _ = try io.vtable.netWrite(io.userdata, self.socket.handle, buf, &.{}, 0);
    return buf.len;
}

fn close(ctx: *anyopaque, io: std.Io, allocator: Allocator) void {
    const self: *NetStream = @ptrCast(@alignCast(ctx));
    io.vtable.netClose(io.userdata, &.{self.socket.handle});
    allocator.free(self.host);
    allocator.destroy(self);
}

fn status(ctx: *anyopaque, allocator: Allocator) anyerror![]const u8 {
    const self: *NetStream = @ptrCast(@alignCast(ctx));
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

    return try std.fmt.allocPrint(allocator, "{s} Connected: {s}:{d}  BW: {s}", .{
        @tagName(self.mode), self.host, self.port, bw_str,
    });
}

pub const TcpListener = struct {
    server: net.Server,
    io: std.Io,
    port: u16,

    pub fn accept(self: *TcpListener, allocator: Allocator) !Stream {
        const client = try self.server.accept(self.io);
        const host = try std.fmt.allocPrint(allocator, "{}", .{client.socket.address});
        errdefer allocator.free(host);

        const ns = try allocator.create(NetStream);
        errdefer allocator.destroy(ns);

        ns.* = .{
            .socket = client.socket,
            .mode = .TCP,
            .io = self.io,
            .host = host,
            .port = self.port,
        };
        return .{
            .ctx = ns,
            .readFn = read,
            .writeFn = write,
            .closeFn = close,
            .statusFn = status,
        };
    }

    pub fn deinit(self: *TcpListener) void {
        self.server.deinit(self.io);
    }
};

pub fn listen(io: std.Io, port: u16) !TcpListener {
    const address = net.IpAddress{ .ip4 = net.Ip4Address.unspecified(port) };
    const server = try address.listen(io, .{});
    return .{
        .server = server,
        .io = io,
        .port = port,
    };
}

pub fn parseHostPort(text: []const u8) !struct { host: []const u8, port: u16 } {
    if (text.len == 0) return error.InvalidAddress;

    if (text[0] == '[') {
        const close_bracket = std.mem.indexOfScalar(u8, text, ']') orelse return error.InvalidAddress;
        const host = text[1..close_bracket];
        if (close_bracket + 1 >= text.len) return error.InvalidPort;
        if (text[close_bracket + 1] != ':') return error.InvalidAddress;
        const port = try std.fmt.parseInt(u16, text[close_bracket + 2 ..], 10);
        return .{ .host = host, .port = port };
    }

    if (std.mem.indexOfScalar(u8, text, ':')) |i| {
        const host = text[0..i];
        const port = try std.fmt.parseInt(u16, text[i + 1 ..], 10);
        return .{ .host = host, .port = port };
    }

    return error.InvalidAddress;
}
