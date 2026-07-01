const std = @import("std");
const vaxis = @import("vaxis");

const Serial = @import("serial.zig");
const Record = @import("record.zig").Record;
const RecordStore = @import("record_store.zig").RecordStore;
const StreamManager = @import("stream_manager.zig").StreamManager;

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

const StatusBar = struct {
    up_time: []const u8,
    error_msg: []const u8,
    mode: []const u8,
    mode_offset: usize,
    bar_width: usize,

    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *StatusBar = @ptrCast(@alignCast(ptr));
        var ns: std.ArrayList(vxfw.SubSurface) = .empty;

        if (self.up_time.len > 0) {
            try ns.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try (vxfw.Text{ .text = self.up_time }).widget().draw(ctx),
            });
        }

        if (self.error_msg.len > 0) {
            try ns.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = @intCast(self.up_time.len) },
                .surface = try (vxfw.Text{
                    .text = self.error_msg,
                    .style = .{ .fg = .{ .index = 1 } },
                }).widget().draw(ctx),
            });
        }

        const error_end = self.up_time.len +| self.error_msg.len;
        if (self.mode_offset > error_end) {
            const pad_len = self.mode_offset - error_end;
            const pad = try ctx.arena.alloc(u8, pad_len);
            @memset(pad, ' ');
            try ns.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = @intCast(error_end) },
                .surface = try (vxfw.Text{ .text = pad }).widget().draw(ctx),
            });
        }

        if (self.mode.len > 0) {
            try ns.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = @intCast(self.mode_offset) },
                .surface = try (vxfw.Text{ .text = self.mode }).widget().draw(ctx),
            });
        }

        return .{
            .size = .{ .width = @intCast(self.bar_width), .height = 1 },
            .widget = .{
                .userdata = self,
                .eventHandler = struct {
                    fn eh(_: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) anyerror!void {}
                }.eh,
                .drawFn = drawFn,
            },
            .buffer = &.{},
            .children = ns.items,
        };
    }

    fn widget(self: *StatusBar) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = struct {
                fn eh(_: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) anyerror!void {}
            }.eh,
            .drawFn = drawFn,
        };
    }
};

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

    record_store: RecordStore,
    stream_manager: StreamManager,

    state: ZerialState = .Home,

    pub fn widget(self: *Tui) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Tui.typeErasedEventHandler,
            .drawFn = Tui.typeErasedDrawFn,
        };
    }

    pub fn init(self: *Tui, io: std.Io, allocator: Allocator, appdata_dir: []const u8, serial_opts: Serial.Options) !void {
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
            .record_store = try RecordStore.init(allocator),
            .stream_manager = StreamManager.init(io, allocator),
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
        self.send_view.write_queue = &self.stream_manager.write_queue;
        self.send_view.appdata_dir = self.appdata_dir;
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
            .filtered_list_ptr = &self.send_view.filtered_list,
            .drop_down_list_ptr = &self.send_view.drop_down.list,
            .current_file_ptr = &self.save_view.current_file,
        };
        try self.load_view.loadLastHistory(io);

        if (serial_opts.port.len > 0) {
            self.stream_manager.open(serial_opts) catch |e| {
                self.stream_manager.last_error = e;
                return;
            };
            self.config_view.is_stream_open = true;
        }
    }

    pub fn deinit(self: *Tui) void {
        self.stream_manager.deinit();
        self.record_store.deinit(self.allocator);
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
                while (try self.stream_manager.read_queue.tryPop()) |record| {
                    try self.record_store.addRecord(self.allocator, record);
                }

                while (try self.event_queue.tryPop()) |tevent| {
                    switch (tevent) {
                        .ScrollUp => self.record_store.scrollUp(),
                        .ScrollDown => self.record_store.scrollDown(),
                        .PageUp => self.record_store.pageUp(),
                        .PageDown => self.record_store.pageDown(),
                        .StreamOpenClose => {
                            if (!self.stream_manager.isOpen()) {
                                const cfg = self.config_view.getSerialConfigOptions();

                                self.stream_manager.open(cfg) catch |e| {
                                    self.stream_manager.last_error = e;
                                    return ctx.consumeAndRedraw();
                                };
                                self.config_view.is_stream_open = true;
                                self.state = .Home;
                                try ctx.requestFocus(self.widget());
                            } else {
                                self.stream_manager.close();
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
            else => {
                switch (self.state) {
                    .SendView => try self.send_view.handleEvent(ctx, event),
                    .Configuration => try self.config_view.handleEvent(ctx, event),
                    .SaveOverlay => try self.save_view.handleEvent(ctx, event),
                    .LoadOverlay => try self.load_view.handleEvent(ctx, event),
                    else => {},
                }
            },
        }
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Tui = @ptrCast(@alignCast(ptr));

        const max = ctx.max.size();

        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        var row: i17 = 0;

        const viewable_records = try self.record_store.viewable(ctx.arena, max.height);
        self.stream_view.records = viewable_records;

        const up_time_str = try std.fmt.allocPrint(ctx.arena, "  Up Time: {d:.1}s  ", .{
            self.stream_manager.upTimeSeconds(),
        });

        const error_str = if (self.stream_manager.last_error) |e|
            try std.fmt.allocPrint(ctx.arena, "Error: {s}  ", .{@errorName(e)})
        else
            "";

        const mode_str = if (self.stream_view.visual_mode) blk: {
            const start = @min(self.stream_view.visual_anchor, self.stream_view.index);
            const end = @max(self.stream_view.visual_anchor, self.stream_view.index);
            break :blk try std.fmt.allocPrint(ctx.arena, " VISUAL {} lines ", .{end - start + 1});
        } else " NORMAL ";

        const bar_width = ctx.max.width.? -| 2;
        const mode_offset = bar_width -| mode_str.len;

        const bar_row = try ctx.arena.create(StatusBar);
        bar_row.* = .{
            .up_time = up_time_str,
            .error_msg = error_str,
            .mode = mode_str,
            .mode_offset = mode_offset,
            .bar_width = bar_width,
        };

        try children.append(ctx.arena, .{
            .origin = .{ .row = row, .col = 0 },
            .surface = try (vxfw.Border{
                .child = bar_row.widget(),
            }).widget().draw(ctx.withConstraints(.{ .width = ctx.max.width.? }, ctx.max)),
        });

        if (self.stream_manager.isOpen()) {
            try children.append(ctx.arena, .{
                .origin = .{ .row = row + 1, .col = @intCast(up_time_str.len + 2) },
                .surface = try (vxfw.Text{
                    .text = self.stream_manager.statusText(ctx.arena) catch {
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
};
