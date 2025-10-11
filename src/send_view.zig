const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;
const vxfw = vaxis.vxfw;

pub const SendView = struct {
    input: vxfw.TextField,
    components: [2]vxfw.SubSurface = undefined,

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
            .key_press => |key| {
                defer {
                    if (key.matches(vaxis.Key.enter, .{})) {
                        self.input.deleteToStart();
                    }
                }
                // handle special logic for send view before sending data to TextField
                return self.input.handleEvent(ctx, event);
            },
            else => {},
        }

        return;
    }

    pub fn onSubmit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const tui: *@import("tui.zig").Tui = @ptrCast(@alignCast(ptr));

        _ = tui.write_queue.tryPush(try tui.allocator.dupe(u8, str));

        return ctx.consumeAndRedraw();
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *SendView = @ptrCast(@alignCast(ptr));
        //  ---------------------
        // | send: *I**** | CRLF |
        //  ---------------------

        const s1: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try (vxfw.Text{ .text = "send:" }).widget().draw(ctx),
        };

        const s2: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = s1.surface.size.width },
            .surface = try self.input.widget().draw(ctx.withConstraints(ctx.min, .{ .width = ctx.max.width.? - s1.surface.size.width - 1, .height = 1 })),
        };

        self.components[0] = s1;
        self.components[1] = s2;

        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = &self.components,
        };
    }
};
