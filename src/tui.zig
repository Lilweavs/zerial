const std = @import("std");
const vaxis = @import("vaxis");
const Serial = @import("serial.zig");
const NetStream = @import("net_stream.zig");

const Record = @import("record.zig");
const CircularArray = @import("circular_array.zig").CircularArray;
const RecordArray = CircularArray(Record);

const ser_utils = @import("serial");

const Allocator = std.mem.Allocator;

const vxfw = vaxis.vxfw;

var rx_buffer: [1024 * 32]u8 = undefined;
var tx_buffer: [1024 * 32]u8 = undefined;

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

fn zerialStateToString(state: ZerialState) []const u8 {
    return switch (state) {
        .Home => "VIEW",
        .SendView => "SEND",
        .Configuration => "CONFIG",
    };
}

fn zerialStateToColor(state: ZerialState) u8 {
    return switch (state) {
        .Home => 0,
        .SendView => 1,
        .Configuration => 2,
    };
}

const StatusLineData = struct {
    port: []const u8 = "",
    baudrate: u32 = 115200,
    is_open: bool = false,
    bandwidth: u8 = 0,
    bps: u32 = 0,
};

const ConfigView = @import("config_view.zig").ConfigView;
const StreamView = @import("serial_monitor.zig").StreamView;
const SendView = @import("send_view.zig").SendView;

pub const SerialStream = union(enum) {
    Serial,
    NetStream,
};

// serial: Serial,
// net: NetStream,
// stream_mode: SerialStream = .Serial,

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

    // Views
    stream_view: StreamView,
    // send_view: SendView,
    // help_view: HelpView,
    config_view: ConfigView,

    stream: ?Stream = null,
    stream_status: enum(u8) { Open, Closed } = .Closed,

    records: RecordArray,

    status_line: StatusLineData = .{},
    refresh: bool = false,

    state: ZerialState = .Home,

    write_queue: vaxis.Queue([]const u8, 8),
    read_queue: vaxis.Queue(Record, 64),

    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,

    last_error: ?anyerror = null,

    up_time: std.Io.Timestamp = .zero,
    bps: f32 = 0,

    cli: bool = false,

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
            .records = try RecordArray.initCapacity(allocator, 1024),
            .read_queue = .init(io),
            .write_queue = .init(io),
        };
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
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Tui = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *Tui, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                try self.config_view.handleEvent(ctx, event);
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
                    else => {
                        if (key.matches('o', .{ .ctrl = true })) {
                            self.closeStream();
                            return;
                        }
                        if (key.matches('o', .{})) {
                            self.state = .Configuration;
                            self.deinitDropDown();
                            self.config_view.port_dropdown.list = try enumerateSerialPorts(self.io, self.allocator);
                            return ctx.consumeAndRedraw();
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

        const up_time_str = try std.fmt.allocPrint(ctx.arena, "UpTime: {d:.1} |", .{
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

    // const surf = vxfw.Surface.initWithChildren(ctx.arena, self.widget(), max, children.items);

    // var buf = try ctx.arena.alloc(vxfw.Ce)
    // return surf;
    // try children.append(
    //     ctx.arena,
    //     .{
    //         .origin = .{ .row = 0, .col = 0 },
    //         .surface = try (vxfw.Border{
    //             .child = (vxfw.FlexRow{
    //                 .children = &.{
    //                     vxfw.FlexItem{
    //                         .widget = (vxfw.Text{
    //                             .text = try std.fmt.allocPrint(ctx.arena, "{s} | {d}bps", .{
    //                                 if (self.stream_mode == .Serial) try self.serial.getStatus(ctx.arena) else try self.net.getStatus(ctx.arena),
    //                                 @as(u32, @intFromFloat(self.bps)),
    //                             }),
    //                         }).widget(),
    //                         .flex = 0,
    //                     },
    //                     vxfw.FlexItem{
    //                         .widget = (vxfw.Text{
    //                             .text = "",
    //                         }).widget(),
    //                         .flex = 1,
    //                     },
    //                 },
    //             }).widget(),
    //         }).draw(ctx.withConstraints(ctx.min, .{ .height = 3, .width = max.width })),
    //     },
    // );

    // try children.append(ctx.arena, .{
    //     .origin = .{
    //         .row = 3,
    //         .col = 0,
    //     },
    //     .surface = try (vxfw.Border{
    //         .child = self.serial_monitor.widget(),
    //     }).draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = max.height - 3 })),
    // });

    // if (self.state == .SendView) {
    //     try children.append(
    //         ctx.arena,
    //         .{ .origin = .{
    //             .row = 10,
    //             .col = max.width / 4,
    //         }, .surface = try (vxfw.Border{
    //             .child = self.send_view.widget(),
    //             .labels = &[_]vxfw.Border.BorderLabel{.{
    //                 .text = "Send View",
    //                 .alignment = .top_center,
    //             }},
    //         }).draw(ctx.withConstraints(ctx.min, .{ .width = max.width / 2, .height = 10 })) },
    //     );
    // }

    // if (self.state == .Configuration) {
    //     try children.append(ctx.arena, .{
    //         .origin = .{
    //             .row = (max.height - ConfigModel.size.height) / 2 - 5,
    //             .col = (max.width - ConfigModel.size.width) / 2,
    //         },
    //         .surface = try (vxfw.Border{
    //             .child = self.configuration_view.widget(),
    //             .labels = &[_]vxfw.Border.BorderLabel{.{
    //                 .text = "Port Configuration",
    //                 .alignment = .top_center,
    //             }},
    //         }).widget().draw(ctx),
    //     });
    // }
    // }

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

        // check for old binary data
        // if (self.hex_data.getPtrOrNull(self.hex_data.size -| 1)) |tail| {
        //     if (record.rxOrTx != tail.rxOrTx) {
        //         try self.splitRecordHex(record, 32);
        //     } else {
        //         const hex = tail.text;
        //         if (hex.len < 32) {
        //             const remaining = 32 - hex.len;

        //             if (record.text.len >= remaining) {
        //                 tail.text = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ hex, record.text[0..remaining] });
        //                 try self.splitRecordHex(.{
        //                     .rxOrTx = record.rxOrTx,
        //                     .text = record.text[remaining..],
        //                     .time = record.time,
        //                 }, 32);
        //             } else {
        //                 tail.text = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ hex, record.text });
        //             }
        //             self.allocator.free(hex);
        //         } else {
        //             try self.splitRecordHex(record, 32);
        //         }
        //     }
        // } else {
        //     try self.splitRecordHex(record, 32);
        // }
    }

    const Options = @import("serial.zig").Options;

    const StreamConfig = union(enum) {
        ser_cfg: Options,
        net_cfg: NetConfig,
    };

    const NetConfig = struct {
        addr: std.net.Address,
        mode: NetStream.NetMode,
    };

    pub fn openStream(self: *Tui, config: StreamConfig) !void {
        switch (config) {
            .ser_cfg => |cfg| {
                if (self.serial.is_open) return;
                self.stream_mode = .Serial;
                self.serial.openWithConfiguration(cfg) catch return;
                self.reader = self.serial.getReaderInterface();
                self.writer = self.serial.getWriterInterface();
            },
            .net_cfg => |cfg| {
                if (self.net.is_open) return;
                self.stream_mode = .NetStream;
                self.net.connect(cfg.addr, .TCP) catch return;
                self.reader = self.net.getReaderInterface();
                self.writer = self.net.getWriterInterface();
            },
        }

        // self.is_listening = true;
        // self.configuration_view.is_stream_open = true;
        // self.reader_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, Tui.streamReaderThread, .{self});
        // self.reader_thread.?.detach();
        // self.writer_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, Tui.streamWriterThread, .{self});
        // self.writer_thread.?.detach();
        // self.state = .Home;
    }

    pub fn closeStream(self: *Tui) void {
        if (self.stream_status == .Open) {
            self.stream_status = .Closed;
            self.reader_thread.?.join();
            self.writer_thread.?.join();
            self.reader_thread = null;
            self.writer_thread = null;
        }

        if (self.stream) |stream| {
            stream.close(self.io, self.allocator);
        }
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
        //TODO: send close port event
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

        // while (self.is_listening) {
        //     std.Thread.sleep(1 * std.time.ns_per_ms);

        //     if (self.reader.?.stream(&buffer.writer, .unlimited)) |bytes_read| {
        //         const dt = @as(f32, @floatFromInt(begin - std.time.milliTimestamp())) / 1000.0;
        //         bps += @intCast(bytes_read);
        //         if (dt > 1.0) {
        //             self.bps = @as(f32, @floatFromInt(bps)) / dt;
        //             bps = 0;
        //             begin = std.time.milliTimestamp();
        //             // self.bps = alpha * bps + (1.0 - alpha) * self.bps;
        //         }
        //         // const bps = @as(f32, @floatFromInt(@as(i64, @intCast(bytes_read)) * (end - begin))) / std.time.ms_per_s;

        //         if (bytes_read == 0) continue;

        //         var token: NewLineIterator = .{
        //             .buffer = rx_buffer[0..bytes_read],
        //         };

        //         while (token.next()) |record| {
        //             try self.stream_view.append(.{
        //                 .text = try self.stream_view.allocator.dupe(u8, record),
        //                 .time = std.time.milliTimestamp(),
        //                 .rxOrTx = .RX,
        //             });
        //         }

        //         _ = std.Io.Writer.consumeAll(&buffer.writer);
        //         self.stream_view.snap = .Bot;
        //         self.refresh = true;
        //     } else |_| {}
        // }
    }
};

const NewLineIterator = struct {
    buffer: []const u8,
    delimiter: u8 = '\n',
    index: usize = 0,

    const Self = @This();

    pub fn init(buf: []const u8) Self {
        return .{
            .buffer = buf,
        };
    }

    pub fn next(self: *Self) ?[]const u8 {
        const start = self.index;

        if (start >= self.buffer.len) return null;

        while (self.index < self.buffer.len) : (self.index += 1) {
            if (self.buffer[self.index] == self.delimiter) {
                self.index += 1;
                return self.buffer[start..self.index];
            }
        }
        self.index = self.buffer.len;
        return self.buffer[start..];
    }
};

test "NewLineIterator" {
    const test1: []const u8 = "Hello\nWorld";

    var iter = NewLineIterator{
        .buffer = test1,
    };

    try std.testing.expectEqualSlices(u8, "Hello\n", iter.next().?);
    try std.testing.expectEqualSlices(u8, "World", iter.next().?);
}

test "basic newline splitting" {
    const input = "Hello\nWorld";

    var it = NewLineIterator.init(input);

    try std.testing.expectEqualSlices(u8, "Hello\n", it.next().?);
    try std.testing.expectEqualSlices(u8, "World", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "trailing newline" {
    const input = "Hello\nWorld\n";

    var it = NewLineIterator.init(input);

    try std.testing.expectEqualSlices(u8, "Hello\n", it.next().?);
    try std.testing.expectEqualSlices(u8, "World\n", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "no newline at all" {
    const input = "HelloWorld";

    var it = NewLineIterator.init(input);

    try std.testing.expectEqualSlices(u8, "HelloWorld", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "empty input" {
    const input = "";

    var it = NewLineIterator.init(input);

    try std.testing.expect(it.next() == null);
}

test "multiple consecutive newlines" {
    const input = "A\n\nB\n";

    var it = NewLineIterator.init(input);

    try std.testing.expectEqualSlices(u8, "A\n", it.next().?);
    try std.testing.expectEqualSlices(u8, "\n", it.next().?);
    try std.testing.expectEqualSlices(u8, "B\n", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "single character lines" {
    const input = "a\nb\nc\n";

    var it = NewLineIterator.init(input);

    try std.testing.expectEqualSlices(u8, "a\n", it.next().?);
    try std.testing.expectEqualSlices(u8, "b\n", it.next().?);
    try std.testing.expectEqualSlices(u8, "c\n", it.next().?);
    try std.testing.expect(it.next() == null);
}
