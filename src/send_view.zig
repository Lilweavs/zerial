const std = @import("std");
const vaxis = @import("vaxis");
const DropDown = @import("dropdown.zig").DropDown;
const Allocator = std.mem.Allocator;
const HorizontalLine = @import("HorizontalLine.zig").HorizontalLine;
const vxfw = vaxis.vxfw;

pub const SendView = struct {
    input: vxfw.TextField,
    history_visible: bool = false,
    history_list: DropDown,
    write_queue: *vaxis.Queue([]const u8, 32),
    delimiter: Delimiter = .CRLF,

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
        self.history_list.deinit(allocator);
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
                self.history_list.list_view.children.builder.userdata = &self.history_list;
            },
            .key_press => |key| {
                if (key.matches('h', .{ .ctrl = true })) {
                    self.history_visible = !self.history_visible;
                    return ctx.consumeAndRedraw();
                }

                if (key.matches('l', .{ .ctrl = true })) {
                    var i: u2 = @intFromEnum(self.delimiter);
                    i +%= 1;
                    self.delimiter = @enumFromInt(i);
                    // self.history_visible = !self.history_visible;
                    return ctx.consumeAndRedraw();
                }

                if (self.history_visible) {
                    if (key.matches(vaxis.Key.enter, .{})) {
                        if (self.history_list.list.items.len == 0) return;

                        const to_send = self.history_list.list.items[self.history_list.list_view.cursor].text;

                        _ = self.write_queue.tryPush(try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ to_send, getDelimiter(self.delimiter) }));
                        return ctx.consumeAndRedraw();
                    }

                    if (key.matches('d', .{})) {
                        if (self.history_list.list.items.len == 0) return;

                        const ptr = self.history_list.list.orderedRemove(self.history_list.list_view.cursor);
                        defer ctx.alloc.free(ptr.text);
                        if (self.history_list.list_view.cursor > self.history_list.list.items.len) {
                            self.history_list.list_view.cursor -|= 1;
                        }
                        return ctx.consumeAndRedraw();
                    }

                    if (key.matches('e', .{})) {
                        if (self.history_list.list.items.len == 0) return;

                        const item = self.history_list.list.items[self.history_list.list_view.cursor];
                        self.input.clearAndFree();
                        try self.input.insertSliceAtCursor(item.text);
                        self.history_visible = false;

                        return ctx.consumeAndRedraw();
                    }

                    return self.history_list.handleEvent(ctx, event);
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
            else => {},
        }

        return;
    }

    pub fn onSubmit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const self: *SendView = @ptrCast(@alignCast(ptr));

        @import("main.zig").logger.log("\n", .{}) catch {};

        for (self.history_list.list.items) |item| {
            @import("main.zig").logger.log("{s}", .{item.text}) catch {};
            if (std.mem.eql(u8, item.text, str)) {
                break;
            }
        } else try self.history_list.list.append(ctx.alloc, .{
            .text = try ctx.alloc.dupe(u8, str),
        });

        _ = self.write_queue.tryPush(try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ str, getDelimiter(self.delimiter) }));

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
        width += children.items[children.items.len - 1].surface.size.width;

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
        width += children.items[children.items.len - 1].surface.size.width;

        if (self.history_visible) {
            try children.append(ctx.arena, .{ .origin = .{ .row = 1, .col = 0 }, .surface = try (HorizontalLine{ .label = .{ .text = "History", .alignment = .center } }).widget().draw(ctx.withConstraints(ctx.min, ctx.max)) });
            height = 2;

            self.history_list.is_expanded = true;

            try children.append(ctx.arena, .{
                .origin = .{ .row = height, .col = 0 },
                .surface = try self.history_list.widget().draw(ctx.withConstraints(ctx.min, ctx.max)),
            });

            height += children.items[children.items.len - 1].surface.size.height;
        }

        return .{
            .size = .{ .width = width, .height = height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }
};
