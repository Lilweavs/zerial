const std = @import("std");
const vaxis = @import("vaxis");
const DropDown = @import("dropdown.zig").DropDown;
const Allocator = std.mem.Allocator;
const HorizontalLine = @import("HorizontalLine.zig").HorizontalLine;
const vxfw = vaxis.vxfw;
const fuzz = @import("fuzzy.zig");

const event_queue = @import("tui.zig").eventQueue();

pub const SendView = struct {
    input: vxfw.TextField,
    show_history: bool = false,
    drop_down: DropDown = .{},
    history_list: [][]const u8 = &.{},
    filtered_list: std.ArrayList([]const u8) = .empty,
    write_queue: *vaxis.Queue([]const u8, 8) = undefined,
    delimiter: Delimiter = .CRLF,
    allocator: Allocator,

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

    pub fn deinit(self: *SendView, allocator: Allocator) void {
        self.input.deinit();
        self.drop_down.list = self.history_list;
        self.drop_down.deinit(allocator);
        self.filtered_list.deinit(allocator);
    }

    pub fn widget(self: *SendView) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = SendView.typeErasedEventHandler,
            .drawFn = SendView.typeErasedDrawFn,
        };
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
                self.input.onSubmit = onSubmit;
                self.drop_down.list = self.history_list;
            },
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    _ = try event_queue.tryPush(.Home);
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
                    if (key.matches(vaxis.Key.enter, .{ .ctrl = true })) {
                        if (self.drop_down.list.len == 0) return;

                        const to_send = self.drop_down.list[self.drop_down.index];

                        _ = try self.write_queue.tryPush(try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ to_send, getDelimiter(self.delimiter) }));
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
                    // handle special logic for send view before sending data to TextField
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

    pub fn onSubmit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const self: *SendView = @ptrCast(@alignCast(ptr));

        _ = try self.write_queue.tryPush(try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ str, getDelimiter(self.delimiter) }));

        return ctx.consumeAndRedraw();
    }

    pub fn onChange(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const self: *SendView = @ptrCast(@alignCast(ptr));
        self.filtered_list.clearRetainingCapacity();
        if (str.len > 0) {
            const filtered = try fuzz.fuzzList(self.history_list, str, ctx.alloc);
            defer ctx.alloc.free(filtered);
            for (filtered) |item| {
                try self.filtered_list.append(self.allocator, self.history_list[item.idx]);
            }
        } else {
            for (self.history_list) |h| {
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
        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try (vxfw.Text{ .text = "send:" }).widget().draw(ctx),
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
