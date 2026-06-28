const std = @import("std");
const vaxis = @import("vaxis");

const Serial = @import("serial.zig");
const Stream = @import("stream.zig").Stream;
const Record = @import("record.zig").Record;
const NewLineIterator = @import("line_iter.zig").NewLineIterator;

const Allocator = std.mem.Allocator;

const StreamStatus = enum(u8) {
    Closed = 0,
    Open = 1,
};

pub const StreamManager = struct {
    stream: ?Stream = null,
    stream_status: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(StreamStatus.Closed)),
    write_queue: vaxis.Queue([]const u8, 8),
    read_queue: vaxis.Queue(Record, 64),
    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,
    read_buffer: [1024 * 32]u8 = undefined,
    up_time: std.Io.Timestamp = .zero,
    last_error: ?anyerror = null,
    io: std.Io,
    allocator: Allocator,

    pub fn init(io: std.Io, allocator: Allocator) StreamManager {
        return .{
            .io = io,
            .allocator = allocator,
            .write_queue = vaxis.Queue([]const u8, 8).init(io),
            .read_queue = vaxis.Queue(Record, 64).init(io),
        };
    }

    pub fn deinit(self: *StreamManager) void {
        self.stream_status.store(@intFromEnum(StreamStatus.Closed), .monotonic);
        if (self.stream) |s| s.close(self.io, self.allocator);
        self.stream = null;
        while (self.write_queue.drain()) |ptr| {
            self.allocator.free(ptr);
        } else {}
        while (self.read_queue.drain()) |r| {
            self.allocator.free(r.text);
        }
    }

    pub fn isOpen(self: *const StreamManager) bool {
        return self.stream_status.load(.monotonic) == @intFromEnum(StreamStatus.Open);
    }

    pub fn open(self: *StreamManager, cfg: Serial.Options) !void {
        self.stream = try Serial.openStream(self.io, self.allocator, cfg);
        self.stream_status.store(@intFromEnum(StreamStatus.Open), .monotonic);
        self.up_time = std.Io.Timestamp.now(self.io, .awake);
        self.reader_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, StreamManager.streamReaderThread, .{self});
        self.writer_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, StreamManager.streamWriterThread, .{self});
    }

    pub fn close(self: *StreamManager) void {
        self.stream_status.store(@intFromEnum(StreamStatus.Closed), .monotonic);
        if (self.stream) |s| s.close(self.io, self.allocator);
        self.stream = null;
    }

    pub fn upTimeSeconds(self: *const StreamManager) f64 {
        if (self.isOpen()) {
            return @as(f64, @floatFromInt(self.up_time.untilNow(self.io, .awake).toMilliseconds())) / 1000;
        }
        return 0.0;
    }

    pub fn statusText(self: *const StreamManager, arena: Allocator) ![]const u8 {
        const s = self.stream orelse return "";
        return s.status(arena);
    }

    fn streamWriterThread(self: *StreamManager) !void {
        while (self.stream_status.load(.monotonic) == @intFromEnum(StreamStatus.Open)) {
            const msg = try self.write_queue.tryPop() orelse {
                try self.io.sleep(.fromMilliseconds(1), .awake);
                continue;
            };
            errdefer self.allocator.free(msg);

            const stream = self.stream orelse break;
            _ = try stream.write(self.io, msg);
            if (try self.read_queue.tryPush(.{
                .rxOrTx = .TX,
                .text = msg,
                .time = std.Io.Timestamp.now(self.io, .awake).toMilliseconds(),
            }) == false) {
                self.allocator.free(msg);
            }
        }
    }

    fn streamReaderThread(self: *StreamManager) !void {
        while (self.stream_status.load(.monotonic) == @intFromEnum(StreamStatus.Open)) {
            const stream = self.stream orelse break;
            const bytes_read = stream.read(self.io, &self.read_buffer) catch |e| switch (e) {
                error.InputOutput, error.BrokenPipe, error.ConnectionResetByPeer => break,
                else => |err| return err,
            };
            if (bytes_read == 0) break;

            var iter: NewLineIterator = .init(self.read_buffer[0..bytes_read]);
            while (iter.next()) |line| {
                const msg = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(msg);
                if (try self.read_queue.tryPush(.{
                    .rxOrTx = .RX,
                    .text = msg,
                    .time = std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
                }) == false) {
                    self.allocator.free(msg);
                }
            }
        }
    }
};
