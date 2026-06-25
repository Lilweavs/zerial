const std = @import("std");
const vaxis = @import("vaxis");

const Serial = @import("serial.zig");
const Record = @import("record.zig");
const CircularArray = @import("circular_array.zig").CircularArray;
const RecordArray = CircularArray(Record);

const NewLineIterator = @import("line_iter.zig").NewLineIterator;

const ser_utils = @import("serial");

const Allocator = std.mem.Allocator;

const vxfw = vaxis.vxfw;

var rx_buffer: [1024 * 32]u8 = undefined;

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

const ZerialState = enum {
    Home,
    SendView,
    Configuration,
};

const ConfigView = @import("config_view.zig").ConfigView;
const StreamView = @import("serial_monitor.zig").StreamView;
const SendView = @import("send_view.zig").SendView;

const TuiEvent = enum {
    ScrollUp,
    ScrollDown,
    // PageUp,
    // PageDown,
    // OpenStream,
    // CloseStream,
    StreamOpenClose,
    Home,
};

pub const EventQueue = vaxis.Queue(TuiEvent, 8);
var event_queue: EventQueue = undefined;

pub fn eventQueue() *EventQueue {
    return &event_queue;
}

pub const Tui = struct {
    allocator: Allocator,
    io: std.Io,

    stream_view: StreamView,
    send_view: SendView,
    config_view: ConfigView,

    stream: ?Stream = null,
    stream_status: enum(u8) { Open, Closed } = .Closed,

    records: RecordArray,

    state: ZerialState = .Home,

    write_queue: vaxis.Queue([]const u8, 8),
    read_queue: vaxis.Queue(Record, 64),

    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,

    last_error: ?anyerror = null,

    up_time: std.Io.Timestamp = .zero,

    ascii_offset: usize = 10,
    max_lines: usize = 1,
    pub fn widget(self: *Tui) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Tui.typeErasedEventHandler,
            .drawFn = Tui.typeErasedDrawFn,
        };
    }

    pub fn init(self: *Tui, io: std.Io, allocator: Allocator) !void {
        event_queue = .init(io);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream_view = .{},
            .config_view = .{
                .allocator = allocator,
            },
            .send_view = .{
                .input = .{
                    .buf = .init(allocator),
                },
                .allocator = allocator,
            },
            .records = try RecordArray.initCapacity(allocator, 1024),
            .read_queue = .init(io),
            .write_queue = .init(io),
        };
        self.send_view.write_queue = &self.write_queue;
        var arr: std.ArrayList([]const u8) = try .initCapacity(self.allocator, 5);
        try arr.appendSlice(allocator, &.{
            try allocator.dupe(u8, "eth remote 192.168.1.1"),
            try allocator.dupe(u8, "eth stats"),
            try allocator.dupe(u8, "eth info"),
            try allocator.dupe(u8, "adc info"),
            try allocator.dupe(u8, "adc on"),
        });
        self.send_view.history_list = try arr.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *Tui) void {
        self.closeStream();
        while (self.records.popOrNull()) |r| {
            self.allocator.free(r.text);
        }
        self.records.deinit();
        while (self.write_queue.drain()) |ptr| {
            self.allocator.free(ptr);
        } else {}
        while (self.read_queue.drain()) |r| {
            self.allocator.free(r.text);
        }

        self.config_view.deinit(self.allocator);
        self.send_view.deinit(self.allocator);
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Tui = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *Tui, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                try self.config_view.handleEvent(ctx, event);
                try self.send_view.handleEvent(ctx, event);
                try ctx.tick(std.time.ms_per_s / 60, self.widget());
            },
            .tick => {
                try ctx.tick(std.time.ms_per_s / 60, self.widget());
                while (try self.read_queue.tryPop()) |record| {
                    try self.addRecord(record);
                }

                while (try event_queue.tryPop()) |tevent| {
                    switch (tevent) {
                        .ScrollUp => self.ascii_offset = @min(self.ascii_offset + 1, @max(self.records.size, self.records.size -| self.max_lines)),
                        .ScrollDown => self.ascii_offset = @max(self.max_lines, self.ascii_offset -| 1),
                        .StreamOpenClose => {
                            if (self.stream_status == .Closed) {
                                const cfg = self.config_view.getSerialConfigOptions();

                                self.stream = Serial.openStream(self.io, self.allocator, cfg) catch |e| {
                                    self.last_error = e;
                                    return ctx.consumeAndRedraw();
                                };
                                self.stream_status = .Open;
                                self.config_view.is_stream_open = true;
                                self.state = .Home;
                                self.up_time = std.Io.Timestamp.now(self.io, .awake);
                                self.last_error = null;

                                self.reader_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, Tui.streamReaderThread, .{self});

                                self.writer_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, Tui.streamWriterThread, .{self});
                            } else {
                                self.closeStream();
                                self.config_view.is_stream_open = false;
                            }
                        },
                        .Home => {
                            self.state = .Home;
                        },
                    }
                }

                return ctx.consumeAndRedraw();
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
                switch (self.state) {
                    .Configuration => {
                        try self.config_view.handleEvent(ctx, event);
                        return ctx.consumeAndRedraw();
                    },
                    .SendView => {
                        try self.send_view.handleEvent(ctx, event);
                        return ctx.consumeAndRedraw();
                    },
                    else => {
                        if (key.matches('o', .{ .ctrl = true })) {
                            self.closeStream();
                            return;
                        }
                        if (key.matches(':', .{})) {
                            self.state = .SendView;
                        }
                        if (key.matches('o', .{})) {
                            self.state = .Configuration;
                            self.deinitDropDown();
                            self.config_view.port_dropdown.list = try enumerateSerialPorts(self.io, self.allocator);
                        }
                    },
                }
                _ = try self.stream_view.handleEvent(ctx, event);
            },
            else => {},
        }
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Tui = @ptrCast(@alignCast(ptr));

        const max = ctx.max.size();

        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        var col: usize = 0;
        var row: i17 = 0;

        self.max_lines = max.height -| 5;

        var viewable = try std.ArrayList(Record).initCapacity(ctx.arena, ctx.max.height.?);
        var iter = self.records.iterator(self.ascii_offset);

        for (0..max.height -| 5) |_| {
            const line = iter.next() orelse break;
            try viewable.append(ctx.arena, line);
        }

        self.stream_view.records = viewable.items;

        const up_time_str = try std.fmt.allocPrint(ctx.arena, "Up Time: {d:.1}", .{
            if (self.stream_status == .Open)
                @as(f64, @floatFromInt(self.up_time.untilNow(self.io, .awake).toMilliseconds())) / 1000
            else
                0.0,
        });
        try children.append(ctx.arena, .{
            .origin = .{ .row = row, .col = @intCast(col) },
            .surface = try (vxfw.Border{
                .child = (vxfw.Text{ .text = up_time_str }).widget(),
            }).widget().draw(ctx.withConstraints(.{ .width = ctx.max.width.? }, ctx.max)),
        });

        col += children.getLast().surface.size.width;

        if (self.stream_status == .Open) {
            try children.append(ctx.arena, .{
                .origin = .{ .row = row + 1, .col = @intCast(up_time_str.len + 2) },
                .surface = try (vxfw.Text{
                    .text = self.stream.?.status(ctx.arena) catch {
                        return error.OutOfMemory;
                    },
                }).widget().draw(ctx),
            });
            row += children.getLast().surface.size.height + 2;
        } else {
            row += children.getLast().surface.size.height;
        }

        col = 0;

        try children.append(ctx.arena, .{
            .origin = .{ .row = row, .col = @intCast(col) },
            .surface = try (vxfw.Border{
                .child = self.stream_view.widget(),
            }).widget().draw(ctx.withConstraints(ctx.min, ctx.max)),
        });

        if (self.state == .Configuration) {
            try children.append(ctx.arena, .{
                .origin = .{ .row = ctx.max.height.? / 4, .col = ctx.max.width.? / 2 -| 8 },
                .surface = try (vxfw.Border{
                    .child = self.config_view.widget(),
                    .labels = &.{
                        vxfw.Border.BorderLabel{
                            .text = "Stream Config",
                            .alignment = .top_center,
                        },
                    },
                }).widget().draw(ctx.withConstraints(.{ .width = 15 }, ctx.max)),
            });
        } else if (self.state == .SendView) {
            try children.append(ctx.arena, .{
                .origin = .{ .row = ctx.max.height.? / 4, .col = ctx.max.width.? / 2 -| ctx.max.width.? / 4 },
                .surface = try (vxfw.Border{
                    .child = self.send_view.widget(),
                }).widget().draw(ctx.withConstraints(ctx.min, .{ .width = ctx.max.width.? / 2 })),
            });
        }

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    pub fn enumerateSerialPorts(io: std.Io, allocator: Allocator) ![][]const u8 {
        var com_port_iter = try ser_utils.list(io);

        var list: std.ArrayList([]const u8) = .empty;

        while (try com_port_iter.next()) |com_port| {
            try list.append(allocator, try allocator.dupe(u8, com_port.display_name));
        }

        return list.toOwnedSlice(allocator);
    }

    fn deinitDropDown(self: *Tui) void {
        if (self.config_view.port_dropdown.list.len > 0) {
            for (self.config_view.port_dropdown.list) |ptr| {
                self.allocator.free(ptr);
            }
            self.allocator.free(self.config_view.port_dropdown.list);
        }
        self.config_view.port_dropdown.list = &.{};
    }

    /// records are gauranteed to not have multiple new lines. They will either be
    /// 1. msg
    /// 2. msg + \n
    pub fn addRecord(self: *Tui, record: Record) !void {
        // check for old ascii data
        if (self.records.getPtrOrNull(self.records.size -| 1)) |tail| {
            if (record.rxOrTx != tail.rxOrTx or tail.text[tail.text.len -| 1] == '\n') {
                if (self.records.pushDropOldest(record)) |r| self.allocator.free(r.text);
            } else {
                const merged_record = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ tail.text, record.text });
                self.allocator.free(tail.text);
                self.allocator.free(record.text);
                tail.text = merged_record;
            }
        } else {
            if (self.records.pushDropOldest(record)) |r| self.allocator.free(r.text);
        }
    }

    pub fn closeStream(self: *Tui) void {
        self.stream_status = .Closed;
        if (self.stream) |s| s.close(self.io, self.allocator);
        if (self.reader_thread) |t| t.join();
        if (self.writer_thread) |t| t.join();
        self.reader_thread = null;
        self.writer_thread = null;
        self.stream = null;
    }

    fn streamWriterThread(self: *Tui) !void {
        while (self.stream_status == .Open) {
            try self.io.sleep(.fromMilliseconds(1), .awake);
            const msg = try self.write_queue.tryPop() orelse continue;
            errdefer self.allocator.free(msg);

            _ = try self.stream.?.write(self.io, msg);
            // transfer ownership to Record
            if (try self.read_queue.tryPush(.{
                .rxOrTx = .TX,
                .text = msg,
                .time = std.Io.Timestamp.now(self.io, .awake).toMilliseconds(),
            }) == false) {
                self.allocator.free(msg);
            }
        }
    }

    pub fn streamReaderThread(self: *Tui) !void {
        _ = try self.stream.?.read(self.io, &rx_buffer);
        while (self.stream_status == .Open) {
            try self.io.sleep(.fromMilliseconds(1), .awake);
            const bytes_read = try self.stream.?.read(self.io, &rx_buffer);

            var iter: NewLineIterator = .init(rx_buffer[0..bytes_read]);
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
