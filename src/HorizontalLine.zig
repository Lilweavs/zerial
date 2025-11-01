const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Allocator = std.mem.Allocator;

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
