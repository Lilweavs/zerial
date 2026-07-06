const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;
const vxfw = vaxis.vxfw;

pub const HelpView = struct {
    lines: []const []const u8 = &.{},

    pub fn widget(self: *HelpView) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = struct {
                fn eh(_: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) anyerror!void {}
            }.eh,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *HelpView = @ptrCast(@alignCast(ptr));
        return self.drawFn(ctx);
    }

    fn drawFn(self: *HelpView, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        var max_width: u16 = 0;
        for (self.lines) |line| {
            const w: u16 = @intCast(line.len);
            if (w > max_width) max_width = w;
        }

        var row: i17 = 0;
        for (self.lines) |line| {
            try children.append(ctx.arena, .{
                .origin = .{ .row = row, .col = 0 },
                .surface = try (vxfw.Text{ .text = line }).widget().draw(ctx),
            });
            row += 1;
        }

        return .{
            .size = .{ .width = max_width, .height = @intCast(self.lines.len) },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }
};
