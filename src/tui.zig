const std = @import("std");
const vaxis = @import("vaxis");

const Serial = @import("serial.zig");
const Stream = @import("stream.zig").Stream;
const Record = @import("record.zig");
const CircularArray = @import("circular_array.zig").CircularArray;
const RecordArray = CircularArray(Record);

const NewLineIterator = @import("line_iter.zig").NewLineIterator;

const ser_utils = @import("serial");

const Allocator = std.mem.Allocator;

const vxfw = vaxis.vxfw;

const ZerialState = enum {
    Home,
    SendView,
    Configuration,
    SaveOverlay,
    LoadOverlay,
};

const ConfigView = @import("config_view.zig").ConfigView;
const StreamView = @import("serial_monitor.zig").StreamView;
const SendView = @import("send_view.zig").SendView;
const SaveView = @import("save_view.zig").SaveView;
const LoadView = @import("load_view.zig").LoadView;

const TuiEvent = enum {
    ScrollUp,
    ScrollDown,
    PageUp,
    PageDown,
    StreamOpenClose,
    Home,
};

pub const EventQueue = vaxis.Queue(TuiEvent, 8);

pub const Tui = struct {
    allocator: Allocator,
    io: std.Io,
    appdata_dir: []u8,

    stream_view: StreamView,
    send_view: SendView,
    save_view: SaveView,
    load_view: LoadView,
    config_view: ConfigView,

    event_queue: EventQueue,

    stream: ?Stream = null,
    stream_status: enum(u8) { Open, Closed } = .Closed,

    records: RecordArray,

    state: ZerialState = .Home,

    write_queue: vaxis.Queue([]const u8, 8),
    read_queue: vaxis.Queue(Record, 64),

    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,

    read_buffer: [1024 * 32]u8 = undefined,

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

    const history_commands = [_][]const u8{
        "eth remote 192.168.1.1",
        "eth stats",
        "eth info",
        "adc info",
        "adc on",
    };

    pub fn init(self: *Tui, io: std.Io, allocator: Allocator, appdata_dir: []const u8) !void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .event_queue = .init(io),
            .stream_view = .{ .event_queue = undefined },
            .config_view = .{
                .event_queue = undefined,
                .allocator = allocator,
            },
            .send_view = .{
                .event_queue = undefined,
                .input = .{
                    .buf = .init(allocator),
                },
                .allocator = allocator,
            },
            .save_view = undefined,
            .load_view = undefined,
            .records = try RecordArray.initCapacity(allocator, 1024),
            .read_queue = .init(io),
            .write_queue = .init(io),
            .appdata_dir = try allocator.dupe(u8, appdata_dir),
        };
        errdefer allocator.free(self.appdata_dir);
        std.Io.Dir.createDirAbsolute(self.io, self.appdata_dir, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => |err| return err,
        };
        self.stream_view.event_queue = &self.event_queue;
        self.config_view.event_queue = &self.event_queue;
        self.send_view.event_queue = &self.event_queue;
        self.send_view.write_queue = &self.write_queue;
        self.send_view.appdata_dir = self.appdata_dir;
        var arr: std.ArrayList([]const u8) = try .initCapacity(self.allocator, history_commands.len);
        for (history_commands) |cmd| {
            try arr.append(allocator, try allocator.dupe(u8, cmd));
        }
        self.send_view.history_list = try arr.toOwnedSlice(allocator);
        self.save_view = .{
            .input = .{ .buf = .init(allocator) },
            .event_queue = &self.event_queue,
            .allocator = allocator,
            .appdata_dir = self.appdata_dir,
            .history_list = &self.send_view.history_list,
        };
        self.load_view = .{
            .event_queue = &self.event_queue,
            .allocator = allocator,
            .appdata_dir = self.appdata_dir,
            .history_list = &self.send_view.history_list,
            .current_file_ptr = &self.save_view.current_file,
        };
        try self.load_view.loadLastHistory(io);
    }

    pub fn deinit(self: *Tui) void {
        self.stream_status = .Closed;
        if (self.stream) |s| s.close(self.io, self.allocator);
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
        self.save_view.deinit(self.allocator);
        self.load_view.deinit(self.allocator);
        self.allocator.free(self.appdata_dir);
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
                try self.save_view.handleEvent(ctx, event);
                try self.load_view.handleEvent(ctx, event);
                try ctx.tick(std.time.ms_per_s / 60, self.widget());
            },
            .tick => {
                try ctx.tick(std.time.ms_per_s / 60, self.widget());
                while (try self.read_queue.tryPop()) |record| {
                    try self.addRecord(record);
                }

                while (try self.event_queue.tryPop()) |tevent| {
                    switch (tevent) {
                        .ScrollUp => self.ascii_offset = @min(self.ascii_offset + 1, @max(self.records.size, self.records.size -| self.max_lines)),
                        .ScrollDown => self.ascii_offset = @max(self.max_lines, self.ascii_offset -| 1),
                        .PageUp => self.ascii_offset = @min(self.ascii_offset + self.max_lines, @max(self.records.size, self.records.size -| self.max_lines)),
                        .PageDown => self.ascii_offset = @max(self.max_lines, self.ascii_offset -| self.max_lines),
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
                                try ctx.requestFocus(self.widget());
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
                            try ctx.requestFocus(self.widget());
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
                    .SaveOverlay => {
                        if (key.matches(vaxis.Key.escape, .{})) {
                            self.state = .Home;
                            try ctx.requestFocus(self.widget());
                            return ctx.consumeAndRedraw();
                        }
                        try self.save_view.handleEvent(ctx, event);
                        return ctx.consumeAndRedraw();
                    },
                    .LoadOverlay => {
                        if (key.matches(vaxis.Key.escape, .{})) {
                            self.state = .Home;
                            try ctx.requestFocus(self.widget());
                            return ctx.consumeAndRedraw();
                        }
                        try self.load_view.handleEvent(ctx, event);
                        return ctx.consumeAndRedraw();
                    },
                    else => {
                        if (key.matches('s', .{ .ctrl = true })) {
                            self.state = .SaveOverlay;
                            self.save_view.save_sub_mode = .Buttons;
                            self.save_view.save_button_idx = 0;
                            self.save_view.input.clearAndFree();
                            try ctx.requestFocus(self.save_view.widget());
                            return ctx.consumeAndRedraw();
                        }
                        if (key.matches('o', .{ .ctrl = true })) {
                            self.state = .LoadOverlay;
                            self.load_view.listHistFiles(ctx.io) catch {};
                            self.load_view.file_dropdown.index = 0;
                            try ctx.requestFocus(self.load_view.widget());
                            return ctx.consumeAndRedraw();
                        }
                        if (key.matches(':', .{})) {
                            self.state = .SendView;
                            try ctx.requestFocus(self.send_view.input.widget());
                        }
                        if (key.matches('o', .{})) {
                            self.state = .Configuration;
                            try ctx.requestFocus(self.widget());
                            self.config_view.deinitPortDropdown(self.allocator);
                            self.config_view.port_dropdown.list = try self.config_view.enumerateSerialPorts(self.io, self.allocator);
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
        var row: i17 = 0;

        self.max_lines = max.height -| 5;
        self.ascii_offset = @max(self.ascii_offset, @min(self.max_lines, self.records.size));

        var viewable = try std.ArrayList(Record).initCapacity(ctx.arena, ctx.max.height.?);
        var iter = self.records.iterator(self.ascii_offset);

        for (0..max.height -| 5) |_| {
            const line = iter.next() orelse break;
            try viewable.append(ctx.arena, line);
        }

        self.stream_view.records = viewable.items;

        const up_time_str = try std.fmt.allocPrint(ctx.arena, "  Up Time: {d:.1}s  ", .{
            if (self.stream_status == .Open)
                @as(f64, @floatFromInt(self.up_time.untilNow(self.io, .awake).toMilliseconds())) / 1000
            else
                0.0,
        });
        const mode_str = if (self.stream_view.visual_mode) blk: {
            const start = @min(self.stream_view.visual_anchor, self.stream_view.index);
            const end = @max(self.stream_view.visual_anchor, self.stream_view.index);
            break :blk try std.fmt.allocPrint(ctx.arena, " VISUAL {} lines ", .{end - start + 1});
        } else " NORMAL ";

        const bar_width = ctx.max.width.? -| 2;
        const mode_offset = bar_width -| mode_str.len;
        const bar_text = try ctx.arena.alloc(u8, bar_width);
        @memset(bar_text, ' ');
        @memcpy(bar_text[0..up_time_str.len], up_time_str);
        @memcpy(bar_text[mode_offset..][0..mode_str.len], mode_str);

        try children.append(ctx.arena, .{
            .origin = .{ .row = row, .col = 0 },
            .surface = try (vxfw.Border{
                .child = (vxfw.Text{ .text = bar_text }).widget(),
            }).widget().draw(ctx.withConstraints(.{ .width = ctx.max.width.? }, ctx.max)),
        });

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

        try children.append(ctx.arena, .{
            .origin = .{ .row = row, .col = 0 },
            .surface = try (vxfw.Border{
                .child = self.stream_view.widget(),
            }).widget().draw(ctx.withConstraints(ctx.min, .{ .width = ctx.max.width.?, .height = max.height -| @as(u16, @intCast(row)) })),
        });

        if (self.state == .Configuration) {
            const overlay = try (vxfw.Border{
                .child = self.config_view.widget(),
                .labels = &.{
                    vxfw.Border.BorderLabel{
                        .text = "Stream Config",
                        .alignment = .top_center,
                    },
                },
            }).widget().draw(ctx.withConstraints(.{ .width = 15 }, ctx.max));
            const origin_row = (ctx.max.height.? -| overlay.size.height) / 2;
            const origin_col = (ctx.max.width.? -| overlay.size.width) / 2;
            try children.append(ctx.arena, .{ .origin = .{ .row = origin_row, .col = origin_col }, .surface = overlay });
        } else if (self.state == .SendView or self.state == .SaveOverlay or self.state == .LoadOverlay) {
            const child_widget = switch (self.state) {
                .SaveOverlay => self.save_view.widget(),
                .LoadOverlay => self.load_view.widget(),
                .SendView => self.send_view.widget(),
                else => unreachable,
            };
            const border_label: ?[]const u8 = switch (self.state) {
                .SaveOverlay => "Save History",
                .LoadOverlay => "Load History",
                else => null,
            };
            const overlay = blk: {
                var border = vxfw.Border{ .child = child_widget };
                if (border_label) |label| {
                    border.labels = &.{
                        vxfw.Border.BorderLabel{ .text = label, .alignment = .top_center },
                    };
                }
                const label_width: u16 = if (border_label) |l| @intCast(l.len) else 0;
                const min_width: u16 = if (self.state == .SaveOverlay) @max(label_width, 21) + 2 else label_width + 2;
                break :blk try border.widget().draw(ctx.withConstraints(.{ .width = min_width, .height = ctx.min.height }, .{ .width = ctx.max.width.? / 2 }));
            };
            const origin_row = (ctx.max.height.? -| overlay.size.height) / 2;
            const origin_col = (ctx.max.width.? -| overlay.size.width) / 2;
            try children.append(ctx.arena, .{ .origin = .{ .row = origin_row, .col = origin_col }, .surface = overlay });
        }

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    /// records are gauranteed to not have multiple new lines. They will either be
    /// 1. msg
    /// 2. msg + \n
    pub fn addRecord(self: *Tui, record: Record) !void {
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
        self.stream = null;
    }

    fn streamWriterThread(self: *Tui) !void {
        while (self.stream_status == .Open) {
            try self.io.sleep(.fromMilliseconds(1), .awake);
            if (self.stream_status != .Open) break;
            const msg = try self.write_queue.tryPop() orelse continue;
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

    pub fn streamReaderThread(self: *Tui) !void {
        while (self.stream_status == .Open) {
            try self.io.sleep(.fromMilliseconds(1), .awake);
            if (self.stream_status != .Open) break;
            const stream = self.stream orelse break;
            const bytes_read = try stream.read(self.io, &self.read_buffer);

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
