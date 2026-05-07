const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;

pub const DropDown = struct {
    index: usize = 0,
    list: [][]const u8 = &.{},
    description: ?[]const u8 = null,
    is_focused: bool = false,
    is_expanded: bool = false,
    max_height: usize = 5,

    pub fn deinit(self: *DropDown, allocator: Allocator) void {
        if (self.list.len > 0) {
            for (self.list) |ptr| {
                allocator.free(ptr);
            }
            allocator.free(self.list);
        }
        self.list = &.{};
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

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *DropDown = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn handleEvent(self: *DropDown, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.is_expanded = false;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    self.is_expanded = !self.is_expanded;
                }
                if (self.is_expanded and key.matches('j', .{})) {
                    self.index = @min(self.index + 1, self.list.len -| 1);
                    ctx.consumeAndRedraw();
                }
                if (self.is_expanded and key.matches('k', .{})) {
                    self.index -|= 1;
                    ctx.consumeAndRedraw();
                }
                if (self.is_expanded and key.matches('>', .{})) {
                    self.index = self.list.len -| 1;
                    ctx.consumeAndRedraw();
                }
                if (self.is_expanded and key.matches('<', .{})) {
                    self.index = 0;
                    ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
        return;
    }

    pub fn draw(self: *DropDown, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        var col: u16 = 0;
        var row: u16 = 0;

        if (self.is_expanded) {
            for (0..self.list.len) |i| {
                try children.append(ctx.arena, .{
                    .origin = .{ .row = @intCast(i), .col = 0 },
                    .surface = try (vxfw.Text{ .text = self.list[i], .style = .{ .reverse = (i == self.index) } }).widget().draw(ctx),
                });
                col = @max(col, children.getLast().surface.size.width);
            }
            row = @intCast(self.list.len);
        } else {
            if (self.list.len == 0) {
                try children.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try (vxfw.Text{
                        .text = "-----",
                        .style = .{ .reverse = (self.is_focused == true) },
                    }).widget().draw(ctx),
                });
            } else {
                try children.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try (vxfw.Text{
                        .text = self.list[@min(self.index, self.list.len -| 1)],
                        .style = .{ .reverse = (self.is_focused == true) },
                    }).widget().draw(ctx),
                });
            }
            row = 1;
            col = @max(col, children.getLast().surface.size.width);
        }
        // const fudge: u16 = 3;

        return .{
            .size = .{ .width = col, .height = row },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }
};
