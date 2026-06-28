const std = @import("std");
const vaxis = @import("vaxis");
const DropDown = @import("dropdown.zig").DropDown;
const Allocator = std.mem.Allocator;
const HorizontalLine = @import("HorizontalLine.zig").HorizontalLine;
const vxfw = vaxis.vxfw;
const fuzz = @import("fuzzy.zig");

const TuiEvent = @import("tui.zig");
const EventQueue = TuiEvent.EventQueue;

pub const SendView = struct {
    input: vxfw.TextField,
    show_history: bool = false,
    drop_down: DropDown = .{},
    history_list: std.ArrayList([]const u8) = .empty,
    filtered_list: std.ArrayList([]const u8) = .empty,
    event_queue: *EventQueue,
    write_queue: *vaxis.Queue([]const u8, 8) = undefined,
    delimiter: Delimiter = .CRLF,
    allocator: Allocator,
    appdata_dir: []const u8 = &.{},

    const Delimiter = enum(u2) {
        NONE,
        CRLF,
        CR,
        LF,
    };

    fn getDelimiter(d: Delimiter) []const u8 {
        return switch (d) {
            .NONE => "",
            .CRLF => "\r\n",
            .CR => "\r",
            .LF => "\n",
        };
    }

    fn isLineTerminator(s: []const u8) bool {
        return std.mem.eql(u8, s, "\r\n") or std.mem.eql(u8, s, "\r") or std.mem.eql(u8, s, "\n");
    }

    pub fn deinit(self: *SendView, allocator: Allocator) void {
        self.input.deinit();
        self.drop_down.list = &.{};
        self.drop_down.deinit(allocator);
        for (self.history_list.items) |h| allocator.free(h);
        self.history_list.deinit(allocator);
        self.filtered_list.deinit(allocator);
    }

    pub fn widget(self: *SendView) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = SendView.typeErasedCaptureHandler,
            .eventHandler = SendView.typeErasedEventHandler,
            .drawFn = SendView.typeErasedDrawFn,
        };
    }

    fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *SendView = @ptrCast(@alignCast(ptr));
        return self.captureEvent(ctx, event);
    }

    fn captureEvent(self: *SendView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (self.show_history) {
                    if (key.matches('d', .{ .ctrl = true }) or
                        key.matches('j', .{ .ctrl = true }) or
                        key.matches('k', .{ .ctrl = true }) or
                        key.matches('e', .{ .ctrl = true }) or
                        key.matches(vaxis.Key.enter, .{ .ctrl = true }))
                    {
                        return self.handleEvent(ctx, event);
                    }
                }
            },
            else => {},
        }
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *SendView = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *SendView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                self.input.userdata = self;
                self.input.onChange = onChange;
                self.input.onSubmit = onSendSubmit;
                self.drop_down.list = self.history_list.items;
            },
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    _ = try self.event_queue.tryPush(.Home);
                    return;
                }

                if (key.matches(vaxis.Key.backspace, .{ .ctrl = true })) {
                    self.input.deleteToStart();
                }

                if (key.matches('h', .{ .ctrl = true })) {
                    self.show_history = !self.show_history;
                    return ctx.consumeAndRedraw();
                }

                if (key.matches('l', .{ .ctrl = true })) {
                    var i: u2 = @intFromEnum(self.delimiter);
                    i +%= 1;
                    self.delimiter = @enumFromInt(i);
                    return ctx.consumeAndRedraw();
                }

                if (self.show_history) {
                    if (key.matches(vaxis.Key.enter, .{ .ctrl = true }) or key.matches(vaxis.Key.enter, .{ .alt = true })) {
                        if (self.drop_down.list.len == 0) return;

                        const to_send = self.drop_down.list[self.drop_down.index];

                        _ = try self.write_queue.tryPush(try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ to_send, getDelimiter(self.delimiter) }));
                        return ctx.consumeAndRedraw();
                    }

                    if (key.matches('d', .{ .ctrl = true })) {
                        if (self.drop_down.list.len == 0) return;

                        const idx = self.drop_down.index;
                        self.allocator.free(self.history_list.items[idx]);
                        _ = self.history_list.orderedRemove(idx);

                        self.filtered_list.clearRetainingCapacity();
                        for (self.history_list.items) |h| {
                            try self.filtered_list.append(self.allocator, h);
                        }
                        self.drop_down.list = self.filtered_list.items;

                        if (self.drop_down.index >= self.history_list.items.len) {
                            self.drop_down.index = self.history_list.items.len -| 1;
                        }
                        return ctx.consumeAndRedraw();
                    }

                    if (key.matches('j', .{ .ctrl = true })) {
                        return try self.drop_down.handleEvent(ctx, .{ .key_press = .{ .codepoint = 'j' } });
                    }
                    if (key.matches('k', .{ .ctrl = true })) {
                        return try self.drop_down.handleEvent(ctx, .{ .key_press = .{ .codepoint = 'k' } });
                    }

                    if (key.matches('e', .{ .ctrl = true })) {
                        if (self.drop_down.list.len == 0) return;

                        const item = self.drop_down.list[self.drop_down.index];
                        self.input.clearAndFree();
                        try self.input.insertSliceAtCursor(item);

                        return ctx.consumeAndRedraw();
                    }

                    return self.input.handleEvent(ctx, event);
                } else {
                    defer {
                        if (key.matches(vaxis.Key.enter, .{})) {
                            self.input.deleteToStart();
                        }
                    }
                    return self.input.handleEvent(ctx, event);
                }
            },
            .paste => {
                try self.input.insertSliceAtCursor(event.paste);
                return ctx.consumeAndRedraw();
            },
            else => {},
        }

        return;
    }

    pub fn onSendSubmit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const self: *SendView = @ptrCast(@alignCast(ptr));

        const already_in_history = for (self.history_list.items) |h| {
            if (std.mem.eql(u8, h, str)) break true;
        } else false;

        if (!already_in_history and str.len > 1 and !isLineTerminator(str)) {
            try self.history_list.append(self.allocator, try self.allocator.dupe(u8, str));

            self.filtered_list.clearRetainingCapacity();
            for (self.history_list.items) |h| {
                try self.filtered_list.append(self.allocator, h);
            }
            self.drop_down.list = self.filtered_list.items;
        }

        _ = try self.write_queue.tryPush(try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ str, getDelimiter(self.delimiter) }));

        return ctx.consumeAndRedraw();
    }

    pub fn onChange(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const self: *SendView = @ptrCast(@alignCast(ptr));
        self.filtered_list.clearRetainingCapacity();
        if (str.len > 0) {
            const filtered = try fuzz.fuzzList(self.history_list.items, str, ctx.alloc);
            defer ctx.alloc.free(filtered);
            for (filtered) |item| {
                try self.filtered_list.append(self.allocator, self.history_list.items[item.idx]);
            }
        } else {
            for (self.history_list.items) |h| {
                try self.filtered_list.append(self.allocator, h);
            }
        }

        self.drop_down.list = self.filtered_list.items;

        return ctx.consumeAndRedraw();
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *SendView = @ptrCast(@alignCast(ptr));

        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        var width: u16 = 0;
        var height: u16 = 1;

        const label = "send:";
        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try (vxfw.Text{ .text = label }).widget().draw(ctx),
        });

        width += children.items[children.items.len - 1].surface.size.width;

        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = width },
            .surface = try self.input.widget().draw(ctx.withConstraints(ctx.min, .{ .width = ctx.max.width.? - (width + 4), .height = 1 })),
        });
        width += children.getLast().surface.size.width;

        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = width },
            .surface = try (vxfw.Text{
                .text = @tagName(self.delimiter),
                .style = .{
                    .fg = .{
                        .index = 1,
                    },
                },
            }).widget().draw(ctx),
        });
        width += children.getLast().surface.size.width;

        if (self.show_history) {
            try children.append(ctx.arena, .{ .origin = .{ .row = 1, .col = 0 }, .surface = try (HorizontalLine{ .label = .{ .text = "History", .alignment = .center } }).widget().draw(ctx.withConstraints(ctx.min, ctx.max)) });
            height = 2;

            self.drop_down.is_expanded = true;

            try children.append(ctx.arena, .{
                .origin = .{ .row = height, .col = 0 },
                .surface = try self.drop_down.widget().draw(ctx),
            });

            height += children.getLast().surface.size.height;
        }

        return .{
            .size = .{ .width = width, .height = height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }
};
