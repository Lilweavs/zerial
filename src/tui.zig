const std = @import("std");
const vaxis = @import("vaxis");
const Serial = @import("serial.zig");
const NetStream = @import("net_stream.zig");

const Allocator = std.mem.Allocator;

const vxfw = vaxis.vxfw;

var rx_buffer: [1024 * 32]u8 = undefined;
var tx_buffer: [1024 * 32]u8 = undefined;

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

const ConfigModel = @import("config_view.zig").ConfigModel;
const SerialMonitor = @import("serial_monitor.zig").SerialMonitor;
const SendView = @import("send_view.zig").SendView;

pub const SerialStream = union(enum) {
    Serial,
    NetStream,
};

// pub const Stream = struct {
//     isOpen: *const fn (stream: *const Stream) void,
//     getStatus: *const fn (stream: *const Stream) void,
//     readStreaming: *const fn (r: *std.Io.Reader, dest: []u8) std.Io.Reader.Error!usize,
//     writeStreaming: *const fn (r: *std.Io.Reader, dest: []u8) std.Io.Reader.Error!usize,
// };

pub const Tui = struct {
    serial: Serial,
    net: NetStream,
    stream_mode: SerialStream = .Serial,
    is_listening: bool = false,
    configuration_view: ConfigModel,
    serial_monitor: SerialMonitor,
    send_view: SendView,
    allocator: Allocator,

    status_line: StatusLineData = .{},
    refresh: bool = false,

    state: ZerialState = .Home,

    write_queue: vaxis.Queue([]const u8, 32) = .{},

    reader: ?*std.Io.Reader = null,
    writer: ?*std.Io.Writer = null,

    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,

    bps: f32 = 0,

    pub fn widget(self: *Tui) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Tui.typeErasedEventHandler,
            .drawFn = Tui.typeErasedDrawFn,
        };
    }

    pub fn deinit(self: *Tui) void {
        self.closeStream();
        self.serial.deinit();
        self.send_view.deinit(self.allocator);
        self.configuration_view.deinit();
        self.is_listening = false;
        self.serial_monitor.deinit();

        while (self.write_queue.tryPop()) |ptr| {
            self.allocator.free(ptr);
        }
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Tui = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *Tui, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                try ctx.tick(std.time.ms_per_s / 60, self.widget());
                self.configuration_view.button.userdata = self;

                ctx.consumeAndRedraw();
                try self.send_view.handleEvent(ctx, .init);
                return self.configuration_view.handleEvent(ctx, event);
            },
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.state = .Home;
                    return ctx.consumeAndRedraw();
                }

                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }

                switch (self.state) {
                    .Home => {},
                    .SendView => {
                        return self.send_view.handleEvent(ctx, event);
                    },
                    .Configuration => {
                        return self.configuration_view.handleEvent(ctx, event);
                    },
                }

                if (key.matches('v', .{})) {
                    self.serial_monitor.view_state = if (self.serial_monitor.view_state == .Ascii) @import("serial_monitor.zig").State.Binary else @import("serial_monitor.zig").State.Ascii;
                    return ctx.consumeAndRedraw();
                }

                if (key.matches(':', .{})) {
                    self.state = .SendView;
                    return ctx.consumeAndRedraw();
                }

                if (key.matches('e', .{ .ctrl = true })) {
                    self.state = .Configuration;
                    try self.configuration_view.enumerateSerialPorts();
                    ctx.consumeAndRedraw();
                    return;
                }

                return self.serial_monitor.handleEvent(ctx, event);
            },
            .tick => {
                try ctx.tick(std.time.ms_per_s / 60, self.widget());
                if (self.refresh) {
                    ctx.redraw = true;
                }
            },
            else => {},
        }

        return;
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Tui = @ptrCast(@alignCast(ptr));

        const max = ctx.max.size();

        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        try children.append(
            ctx.arena,
            .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try (vxfw.Border{
                    .child = (vxfw.FlexRow{
                        .children = &.{
                            vxfw.FlexItem{
                                .widget = (vxfw.Text{
                                    .text = try std.fmt.allocPrint(ctx.arena, "{s} | {d}bps", .{
                                        if (self.stream_mode == .Serial) try self.serial.getStatus(ctx.arena) else try self.net.getStatus(ctx.arena),
                                        @as(u32, @intFromFloat(self.bps)),
                                    }),
                                }).widget(),
                                .flex = 0,
                            },
                            vxfw.FlexItem{
                                .widget = (vxfw.Text{
                                    .text = "",
                                }).widget(),
                                .flex = 1,
                            },
                        },
                    }).widget(),
                }).draw(ctx.withConstraints(ctx.min, .{ .height = 3, .width = max.width })),
            },
        );

        try children.append(ctx.arena, .{
            .origin = .{
                .row = 3,
                .col = 0,
            },
            .surface = try (vxfw.Border{
                .child = self.serial_monitor.widget(),
            }).draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = max.height - 3 })),
        });

        if (self.state == .SendView) {
            try children.append(
                ctx.arena,
                .{ .origin = .{
                    .row = 10,
                    .col = max.width / 4,
                }, .surface = try (vxfw.Border{
                    .child = self.send_view.widget(),
                    .labels = &[_]vxfw.Border.BorderLabel{.{
                        .text = "Send View",
                        .alignment = .top_center,
                    }},
                }).draw(ctx.withConstraints(ctx.min, .{ .width = max.width / 2, .height = 10 })) },
            );
        }

        if (self.state == .Configuration) {
            try children.append(ctx.arena, .{
                .origin = .{
                    .row = (max.height - ConfigModel.size.height) / 2 - 5,
                    .col = (max.width - ConfigModel.size.width) / 2,
                },
                .surface = try (vxfw.Border{
                    .child = self.configuration_view.widget(),
                    .labels = &[_]vxfw.Border.BorderLabel{.{
                        .text = "Port Configuration",
                        .alignment = .top_center,
                    }},
                }).widget().draw(ctx),
            });
        }

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
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

        self.is_listening = true;
        self.configuration_view.is_stream_open = true;
        self.reader_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, Tui.streamReaderThread, .{self});
        self.reader_thread.?.detach();
        self.writer_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, Tui.streamWriterThread, .{self});
        self.writer_thread.?.detach();
        self.state = .Home;
    }

    pub fn closeStream(self: *Tui) void {
        self.is_listening = false;
        // wait for threads to finish
        std.Thread.sleep(100 * std.time.ns_per_ms);
        self.reader = null;
        self.writer = null;
        self.configuration_view.is_stream_open = false;
        if (self.stream_mode == .Serial) {
            self.serial.close();
        } else {
            self.net.close();
        }
    }

    fn streamWriterThread(self: *Tui) anyerror!void {
        while (self.is_listening) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
            const writer = self.writer orelse continue;

            const to_send = self.write_queue.pop();

            // transfer ownership to Record
            try self.serial_monitor.append(.{
                .text = to_send,
                .time = std.time.milliTimestamp(),
                .rxOrTx = .TX,
            });

            _ = try std.io.Writer.write(writer, to_send);
            try std.io.Writer.flush(writer);

            self.serial_monitor.snap = .Bot;
            self.refresh = true;
        }
    }

    pub fn streamReaderThread(self: *Tui) !void {
        var buffer: std.Io.Writer.Discarding = .init(&rx_buffer);
        // const alpha: f32 = 0.2;
        var bps: u32 = 0;
        var begin = std.time.milliTimestamp();
        while (self.is_listening) {
            std.Thread.sleep(1 * std.time.ns_per_ms);

            if (self.reader.?.stream(&buffer.writer, .unlimited)) |bytes_read| {
                const dt = @as(f32, @floatFromInt(begin - std.time.milliTimestamp())) / 1000.0;
                bps += @intCast(bytes_read);
                if (dt > 1.0) {
                    self.bps = @as(f32, @floatFromInt(bps)) / dt;
                    bps = 0;
                    begin = std.time.milliTimestamp();
                    // self.bps = alpha * bps + (1.0 - alpha) * self.bps;
                }
                // const bps = @as(f32, @floatFromInt(@as(i64, @intCast(bytes_read)) * (end - begin))) / std.time.ms_per_s;

                if (bytes_read == 0) continue;

                var token: NewLineIterator = .{
                    .buffer = rx_buffer[0..bytes_read],
                };

                while (token.next()) |record| {
                    try self.serial_monitor.append(.{
                        .text = try self.serial_monitor.allocator.dupe(u8, record),
                        .time = std.time.milliTimestamp(),
                        .rxOrTx = .RX,
                    });
                }

                _ = std.Io.Writer.consumeAll(&buffer.writer);
                self.serial_monitor.snap = .Bot;
                self.refresh = true;
            } else |_| {}
        }
    }
};

const NewLineIterator = struct {
    buffer: []const u8,
    delimiter: u8 = '\n',
    index: usize = 0,

    const Self = @This();

    pub fn next(self: *Self) ?[]const u8 {
        const start = self.index;

        if (start >= self.buffer.len) {
            return null;
        }

        while (self.index < self.buffer.len) : (self.index += 1) {
            if (self.buffer[self.index] == self.delimiter) {
                break;
            }
        }

        if (self.index + 1 <= self.buffer.len) {
            self.index += 1;
        }
        return self.buffer[start..self.index];
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
