const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;

pub const DropDown = struct {
    list: std.ArrayList(vxfw.Text),
    list_view: vxfw.ListView = .{ .children = .{ .builder = .{ .userdata = undefined, .buildFn = DropDown.widgetBuilder } } },
    description: ?[]const u8 = null,
    is_expanded: bool = false,
    in_focus: bool = false,

    pub fn deinit(self: *DropDown, allocator: Allocator) void {
        // for (self.text.items) |text| {
        //     // allocator.free(text);
        // }
        self.list.deinit(allocator);
    }

    pub fn widget(self: *DropDown) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = DropDown.typeErasedEventHandler,
            .drawFn = DropDown.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *DropDown = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn widgetBuilder(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const DropDown = @ptrCast(@alignCast(ptr));
        if (idx >= self.list.items.len) return null;
        return self.list.items[idx].widget();
    }

    pub fn handleEvent(self: *DropDown, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .focus_in => {
                self.in_focus = true;
                ctx.consumeAndRedraw();
                return;
            },
            .focus_out => {
                self.in_focus = false;
                ctx.consumeAndRedraw();
                return;
            },
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.is_expanded = false;
                    ctx.consumeAndRedraw();
                    return;
                }

                if (key.matches(vaxis.Key.enter, .{})) {
                    self.is_expanded = !self.is_expanded;
                    ctx.consumeAndRedraw();
                    return;
                }

                if (self.is_expanded) {
                    return self.list_view.handleEvent(ctx, event);
                }
            },
            else => {},
        }

        return;
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *DropDown = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *DropDown, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        // const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        var width: u16 = 0;
        var height: u16 = 1;

        const dropdown_len: u16 = 3;

        if (self.description) |description| {
            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try (vxfw.Text{ .text = description }).widget().draw(ctx.withConstraints(ctx.min, .{ .width = @intCast(description.len), .height = 1 })),
            });

            width += @intCast(description.len + dropdown_len);

            if (self.is_expanded) {
                var max_list_length: u16 = 0;
                for (self.list.items) |item| {
                    max_list_length = @max(width, @as(u16, @intCast(item.text.len)));
                }
                try children.append(ctx.arena, vxfw.SubSurface{
                    .origin = .{ .row = 0, .col = width },
                    .surface = try self.list_view.draw(ctx),
                });
                width += children.items[1].surface.size.width;
                height = @intCast(@max(1, self.list.items.len));
            } else {
                const text_len: u16 = @intCast(self.list.items[self.list_view.cursor].text.len);
                try children.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = width },
                    .surface = try (vxfw.Text{ .text = self.list.items[self.list_view.cursor].text, .style = .{ .reverse = self.in_focus } }).widget().draw(ctx.withConstraints(.{ .width = 1, .height = 1 }, .{ .width = text_len, .height = 1 })),
                });
                width += text_len;
            }
        } else {
            if (self.is_expanded) {
                width += dropdown_len;

                var max_list_length: u16 = 0;
                for (self.list.items) |item| {
                    max_list_length = @max(width, @as(u16, @intCast(item.text.len)));
                }
                try children.append(ctx.arena, vxfw.SubSurface{
                    .origin = .{ .row = 0, .col = width },
                    .surface = try self.list_view.draw(ctx),
                });
                width += children.items[children.items.len - 1].surface.size.width;
                height = @intCast(@max(1, self.list.items.len));
            } else {
                const text: []const u8 = if (self.list.items.len == 0) "" else self.list.items[self.list_view.cursor].text;
                const text_len: u16 = @intCast(self.list.items[self.list_view.cursor].text.len);
                try children.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = width },
                    .surface = try (vxfw.Text{ .text = text, .style = .{ .reverse = self.in_focus } }).widget().draw(ctx.withConstraints(.{ .width = 1, .height = 1 }, .{ .width = text_len, .height = 1 })),
                });
                width += text_len;
            }
        }

        const size = vxfw.Size{ .width = width, .height = height };
        var surf = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), size, children.items);
        if (!self.is_expanded and self.description != null) {
            surf.writeCell(@intCast(self.description.?.len + 1), 0, .{ .char = .{ .grapheme = "▼", .width = 1 }, .style = .{} });
        }
        return surf;
    }
};
