const std = @import("std");
const vaxis = @import("vaxis");
const DropDown = @import("dropdown.zig").DropDown;
const Allocator = std.mem.Allocator;
const vxfw = vaxis.vxfw;

pub const HorizontalLine = struct {
    pub const LineLabel = struct {
        text: []const u8,
        alignment: enum {
            left,
            center,
            right,
        },
    };

    label: LineLabel = .{
        .text = "",
        .alignment = .left,
    },

    style: vaxis.Style = .{},

    pub fn widget(self: *const HorizontalLine) vxfw.Widget {
        return .{
            .userdata = @constCast(self),
            .drawFn = HorizontalLine.typeErasedDrawFn,
        };
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *const HorizontalLine = @ptrCast(@alignCast(ptr));

        const max_width = ctx.max.width.?;

        var surf = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = max_width, .height = 1 });

        for (0..max_width) |i| {
            surf.writeCell(@intCast(i), 0, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = .{} });
        }

        // Add border labels
        const text_len: u16 = @intCast(ctx.stringWidth(self.label.text));
        if (text_len != 0) {
            var text_col: u16 = switch (self.label.alignment) {
                .left => 1,
                .center => @max((max_width - text_len) / 2, 1),
                .right => @max(max_width - 1 - text_len, 1),
            };

            var iter = ctx.graphemeIterator(self.label.text);
            while (iter.next()) |grapheme| {
                const text = grapheme.bytes(self.label.text);
                const width: u16 = @intCast(ctx.stringWidth(text));
                surf.writeCell(text_col, 0, .{
                    .char = .{ .grapheme = text, .width = @intCast(width) },
                    .style = self.style,
                });
                text_col += width;
            }
        }

        return surf;
    }
};

pub const SendView = struct {
    input: vxfw.TextField,
    history_visible: bool = false,
    history_list: DropDown,
    write_queue: *vaxis.Queue([]const u8, 32),

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
                @import("main.zig").logger.log("Init Dropdown\n", .{}) catch {};
            },
            .key_press => |key| {
                if (key.matches('h', .{ .ctrl = true })) {
                    self.history_visible = !self.history_visible;
                    return ctx.consumeAndRedraw();
                }

                if (self.history_visible) {
                    if (key.matches(vaxis.Key.enter, .{})) {
                        if (self.history_list.list.items.len == 0) return;

                        const to_send = self.history_list.list.items[self.history_list.list_view.cursor].text;

                        _ = self.write_queue.tryPush(try ctx.alloc.dupe(u8, to_send));
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

        _ = self.write_queue.tryPush(try ctx.alloc.dupe(u8, str));

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
            .surface = try (vxfw.Text{ .text = "CRLF", .style = .{ .fg = .{
                .index = 1,
            } } }).widget().draw(ctx),
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
