const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Stream = struct {
    ctx: *anyopaque,

    readFn: *const fn (ctx: *anyopaque, io: std.Io, buf: []u8) anyerror!usize,
    writeFn: *const fn (ctx: *anyopaque, io: std.Io, buf: []const u8) anyerror!usize,
    statusFn: *const fn (ctx: *anyopaque, allocator: Allocator) anyerror![]const u8,
    closeFn: ?*const fn (ctx: *anyopaque, io: std.Io, allocator: Allocator) void = null,

    pub fn status(self: Stream, allocator: Allocator) anyerror![]const u8 {
        return self.statusFn(self.ctx, allocator);
    }

    pub fn read(self: Stream, io: std.Io, buf: []u8) anyerror!usize {
        return self.readFn(self.ctx, io, buf);
    }

    pub fn write(self: Stream, io: std.Io, buf: []const u8) anyerror!usize {
        return self.writeFn(self.ctx, io, buf);
    }

    pub fn close(self: Stream, io: std.Io, allocator: Allocator) void {
        if (self.closeFn) |f| f(self.ctx, io, allocator);
    }
};
