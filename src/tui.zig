const std = @import("std");
const vaxis = @import("vaxis");
const Serial = @import("serial.zig");
const NetStream = @import("net_stream.zig");

const Allocator = std.mem.Allocator;

const vxfw = vaxis.vxfw;

var buffer: [1024 * 32]u8 = undefined;

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
pub const Tui = struct {
    serial: Serial,
    is_listening: bool = false,
    configuration_view: ConfigModel,
    serial_monitor: SerialMonitor,
    send_view: SendView,
    allocator: Allocator,

    status_line: StatusLineData = .{},
    refresh: bool = false,

    prev_rows: usize = 0,
    state: ZerialState = .Home,

    write_queue: vaxis.Queue([]const u8, 32) = .{},

    reader: ?*std.io.Reader = null,
    writer: ?*std.io.Writer = null,

    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,

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
        self.send_view.input.deinit();
        self.configuration_view.deinit();
        self.is_listening = false;
        self.serial_monitor.deinit();
    }

    pub fn append() void {}

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Tui = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *Tui, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                try ctx.tick(std.time.ms_per_s / 60, self.widget());
                try self.serial.init();
                self.configuration_view.serial = &self.serial;
                self.configuration_view.button.userdata = self;

                ctx.consumeAndRedraw();
                return self.configuration_view.handleEvent(ctx, event);
            },
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.state = .Home;
                    return ctx.consumeAndRedraw();
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

                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
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
                    self.refresh = false;
                    return ctx.consumeAndRedraw();
                }
            },
            else => {},
        }

        return;
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Tui = @ptrCast(@alignCast(ptr));

        const max = ctx.max.size();

        const border = vxfw.Border{ .child = self.serial_monitor.widget() };

        const b1 = vxfw.Border{ .child = self.send_view.widget() };

        const status_line_text: []const u8 = blk: {
            if (self.serial.is_open) {
                break :blk try std.fmt.allocPrint(ctx.arena, "Port: {s}@{d} Bandwidth: {d}bps|{d}%", .{ self.serial.port.?, self.serial.baudrate, self.serial.bps, (self.serial.bps / self.serial.baudrate) });
            } else {
                break :blk try std.fmt.allocPrint(ctx.arena, "Port: Disconnected", .{});
            }
        };

        const status_line_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try (vxfw.Border{
                .child = (vxfw.Text{ .text = status_line_text }).widget(),
            }).draw(ctx.withConstraints(ctx.min, .{ .height = 3, .width = max.width })),
        };

        const status_mode_text = try std.fmt.allocPrint(ctx.arena, "\n {s}", .{zerialStateToString(self.state)});

        const status_mode_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = status_line_surface.surface.size.width },
            .surface = try ((vxfw.Text{ .text = status_mode_text, .style = .{ .bg = .{ .index = zerialStateToColor(self.state) } } }).widget()).draw(ctx.withConstraints(.{ .width = @intCast(status_mode_text.len), .height = 3 }, .{})),
        };

        const send_view_surface: vxfw.SubSurface = .{
            .origin = .{ .row = status_line_surface.surface.size.height, .col = 0 },
            .surface = try b1.draw(ctx.withConstraints(ctx.min, .{ .height = 3, .width = max.width })),
        };

        const data_view_surface: vxfw.SubSurface = .{
            .origin = .{ .row = send_view_surface.origin.row + send_view_surface.surface.size.height, .col = 0 },
            .surface = try border.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = max.height - send_view_surface.surface.size.height - status_line_surface.surface.size.height })),
        };

        var num_surfaces: usize = 4;
        if (self.state == .Configuration) {
            num_surfaces = 5;
        }

        const children = try ctx.arena.alloc(vxfw.SubSurface, num_surfaces);
        children[0] = status_line_surface;
        children[1] = status_mode_surface;
        children[2] = send_view_surface;
        children[3] = data_view_surface;

        if (self.state == .Configuration) {
            const configure_view: vxfw.SubSurface = .{
                .origin = .{ .row = (max.height - ConfigModel.size.height) / 2 - 5, .col = (max.width - ConfigModel.size.width) / 2 },
                // .surface = try self.configuration_view.widget().draw(ctx),
                .surface = try (vxfw.Border{
                    .child = self.configuration_view.widget(),
                    .labels = &[_]vxfw.Border.BorderLabel{.{
                        .text = "Port Configuration",
                        .alignment = .top_center,
                    }},
                }).widget().draw(ctx.withConstraints(ctx.min, .{ .width = ConfigModel.size.width, .height = ConfigModel.size.height })),
            };
            children[4] = configure_view;
        }

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    const Options = @import("serial.zig").Options;

    const StreamConfig = union(enum) {
        ser_cfg: Options,
        net_cfg: NetConfig,
    };

    const NetConfig = struct {
        ip_address: []const u8,
        port: u16,
    };

    pub fn openStream(self: *Tui, config: StreamConfig) !void {
        switch (config) {
            .ser_cfg => |cfg| {
                if (self.serial.is_open) return;

                try self.serial.openWithConfiguration(cfg);
                self.is_listening = true;
                self.reader = &self.serial.reader.?.interface;
                self.writer = &self.serial.writer.?.interface;

                std.debug.print("{any}\n", .{cfg});
            },
            .net_cfg => |cfg| {
                std.debug.print("{any}\n", .{cfg});
            },
        }
        self.reader_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, Tui.streamReaderThread, .{self});
        self.reader_thread.?.detach();
        self.writer_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, Tui.streamWriterThread, .{self});
        self.writer_thread.?.detach();
        self.state = .Home;
    }

    pub fn closeStream(self: *Tui) void {
        if (!self.serial.is_open) return;
        self.is_listening = false;
        // wait for threads to finish
        std.Thread.sleep(100 * std.time.ns_per_ms);
        self.serial.close();

        // self.reader_thread.?.join();
        // self.writer_thread.?.join();
    }

    fn streamWriterThread(self: *Tui) anyerror!void {
        while (self.is_listening) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
            const writer = if (self.writer) |w| w else continue;

            const to_send = self.write_queue.pop();

            // transfer ownership to Record
            try self.serial_monitor.append(.{
                .text = @constCast(to_send),
                .rxOrTx = .TX,
                .time = std.time.milliTimestamp(),
            });

            _ = try std.io.Writer.write(writer, to_send);
            try std.io.Writer.flush(writer);
            // try self.serial.write(to_send);

            self.serial_monitor.snap_to_bottom = true;
            self.refresh = true;
        }
    }

    pub fn streamReaderThread(self: *Tui) !void {
        var writer = std.io.Writer.Discarding.init(&buffer);

        while (self.is_listening) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
            const reader = if (self.reader) |r| r else continue;
            if (reader.streamRemaining(&writer.writer)) |bytes_read| {
                if (bytes_read == 0) continue;
                (@import("main.zig").logger.log("{s}\n", .{buffer[0..bytes_read]})) catch {};

                var token: NewLineIterator = .{
                    .buffer = buffer[0..bytes_read],
                };

                while (token.next()) |record| {
                    try self.serial_monitor.append(.{
                        .time = std.time.milliTimestamp(),
                        .text = try self.serial_monitor.allocator.dupe(u8, record),
                        .rxOrTx = .RX,
                    });
                }

                self.serial_monitor.snap_to_bottom = true;
                self.refresh = true;

                _ = std.io.Writer.consumeAll(&writer.writer);
            } else |err| {
                std.debug.print("{t}", .{err});
            }
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
