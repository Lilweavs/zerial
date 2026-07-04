const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Allocator = std.mem.Allocator;

pub const BorderWithTab = struct {
    pub const Tab = struct {
        label: []const u8,
        child: vxfw.Widget,
    };

    tabs: []const Tab = &.{},
    active: usize = 0,
    focused: bool = false,
    style: vaxis.Style = .{},
    active_style: vaxis.Style = .{ .bold = true },
    inactive_style: vaxis.Style = .{ .dim = true },
    border_style: vaxis.Style = .{},

    /// How many tabs the widget is wide, determined by label widths.
    const gap: u16 = 1;

    pub fn widget(self: *BorderWithTab) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *BorderWithTab = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *BorderWithTab = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn handleEvent(self: *BorderWithTab, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.tab, .{})) {
                    if (self.tabs.len > 1) {
                        self.active = (self.active + 1) % self.tabs.len;
                        return ctx.consumeAndRedraw();
                    }
                }
                if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                    if (self.tabs.len > 1) {
                        self.active = (self.active + self.tabs.len - 1) % self.tabs.len;
                        return ctx.consumeAndRedraw();
                    }
                }
            },
            else => {},
        }
        if (self.tabs.len > 0) {
            if (self.tabs[self.active].child.eventHandler) |handler| {
                try handler(self.tabs[self.active].child.userdata, ctx, event);
            }
        }
    }

    fn tabPositions(self: *const BorderWithTab, ctx: vxfw.DrawContext) struct { starts: []u16, total: u16 } {
        const n = self.tabs.len;
        const starts = ctx.arena.alloc(u16, n) catch unreachable;
        var pos: u16 = 0;
        for (self.tabs, 0..) |tab, i| {
            starts[i] = pos;
            const tw: u16 = @intCast(ctx.stringWidth(tab.label) + 4);
            pos += tw + gap;
        }
        pos += gap; // right padding
        return .{ .starts = starts, .total = pos };
    }

    pub fn draw(self: *BorderWithTab, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const n = self.tabs.len;
        if (n == 0) {
            return vxfw.Surface{ .size = .{ .width = 0, .height = 0 }, .widget = self.widget(), .buffer = &.{}, .children = &.{} };
        }

        const tp = self.tabPositions(ctx);
        const starts = tp.starts;
        const total_width = tp.total;

        const active = self.tabs[self.active];
        const active_lw: u16 = @intCast(ctx.stringWidth(active.label));
        const body_left: u16 = starts[self.active];
        const body_right: u16 = starts[self.active] + active_lw + 3;

        const content_max_w: u16 = total_width + 2;
        const content_max_h: ?u16 = if (ctx.max.height) |h| h -| 5 else null;
        const child_ctx = ctx.withConstraints(ctx.min, .{ .width = content_max_w, .height = content_max_h });

        const child = try active.child.draw(child_ctx);
        const min_w: u16 = @max(total_width, body_right + 1);
        const surf_w: u16 = @max(min_w, child.size.width + 2);
        const surf_h: u16 = @max(child.size.height + 5, 5);

        var children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{ .col = 2, .row = 3 },
            .z_index = 0,
            .surface = child,
        };

        var surf = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = surf_w, .height = surf_h }, children);

        const re: u16 = surf_w - 1;
        const be: u16 = surf_h - 1;

        // ---- Row 0: arc above active tab label ----
        //   ╭─────╮   (for "TCP": ╭ at body_left, ─ across, ╮ at body_right)
        if (body_left <= re) {
            surf.writeCell(body_left, 0, .{ .char = .{ .grapheme = "╭", .width = 1 }, .style = self.active_style });
        }
        for (body_left + 1..body_right) |c| {
            if (c <= re) {
                surf.writeCell(@intCast(c), 0, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.active_style });
            }
        }
        if (body_right <= re) {
            surf.writeCell(body_right, 0, .{ .char = .{ .grapheme = "╮", .width = 1 }, .style = self.active_style });
        }

        // ---- Row 1: all tab labels ----
        for (self.tabs, 0..) |tab, i| {
            const left = starts[i];
            const lw: u16 = @intCast(ctx.stringWidth(tab.label));
            if (i == self.active) {
                // active: │ label │
                surf.writeCell(left, 1, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = self.active_style });
                if (left + 1 <= re) {
                    surf.writeCell(left + 1, 1, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = self.active_style });
                }
                var iter = ctx.graphemeIterator(tab.label);
                var tc = left + 2;
                while (iter.next()) |grapheme| {
                    const text = grapheme.bytes(tab.label);
                    const w: u16 = @intCast(ctx.stringWidth(text));
                    if (tc + w <= left + 2 + lw and tc + w <= re + 1) {
                        surf.writeCell(tc, 1, .{ .char = .{ .grapheme = text, .width = @intCast(w) }, .style = self.active_style });
                        tc += w;
                    }
                }
                if (left + lw + 2 <= re) {
                    surf.writeCell(left + lw + 2, 1, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = self.active_style });
                }
                if (left + lw + 3 <= re) {
                    surf.writeCell(left + lw + 3, 1, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = self.active_style });
                }
            } else {
                // inactive:  label  (two spaces before, label, two spaces after)
                if (left <= re) {
                    surf.writeCell(left, 1, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = self.inactive_style });
                }
                if (left + 1 <= re) {
                    surf.writeCell(left + 1, 1, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = self.inactive_style });
                }
                var iter = ctx.graphemeIterator(tab.label);
                var tc = left + 2;
                while (iter.next()) |grapheme| {
                    const text = grapheme.bytes(tab.label);
                    const w: u16 = @intCast(ctx.stringWidth(text));
                    if (tc + w <= left + 2 + lw and tc + w <= re + 1) {
                        surf.writeCell(tc, 1, .{ .char = .{ .grapheme = text, .width = @intCast(w) }, .style = self.inactive_style });
                        tc += w;
                    }
                }
                if (left + lw + 2 <= re) {
                    surf.writeCell(left + lw + 2, 1, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = self.inactive_style });
                }
                if (left + lw + 3 <= re) {
                    surf.writeCell(left + lw + 3, 1, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = self.inactive_style });
                }
            }
        }

        // ---- Row 2: content top border, connecting around active tab ----
        // left edge → active tab left wall
        //   ╭───╯     ╰───╮
        surf.writeCell(0, 2, .{ .char = .{ .grapheme = "╭", .width = 1 }, .style = self.border_style });
        if (body_left > 0) {
            for (1..body_left) |c| {
                surf.writeCell(@intCast(c), 2, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.border_style });
            }
            surf.writeCell(body_left, 2, .{ .char = .{ .grapheme = "╯", .width = 1 }, .style = self.border_style });
        } else {
            surf.writeCell(0, 2, .{ .char = .{ .grapheme = "├", .width = 1 }, .style = self.border_style });
        }

        // gap under active tab body
        for (body_left + 1..body_right) |c| {
            if (c <= re) {
                surf.writeCell(@intCast(c), 2, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = self.active_style });
            }
        }

        // active tab right wall → right edge
        if (body_right < re) {
            if (body_right <= re) {
                surf.writeCell(body_right, 2, .{ .char = .{ .grapheme = "╰", .width = 1 }, .style = self.border_style });
            }
            for (body_right + 1..re) |c| {
                surf.writeCell(@intCast(c), 2, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.border_style });
            }
            surf.writeCell(re, 2, .{ .char = .{ .grapheme = "╮", .width = 1 }, .style = self.border_style });
        } else {
            surf.writeCell(re, 2, .{ .char = .{ .grapheme = "┤", .width = 1 }, .style = self.border_style });
        }

        // ---- Vertical borders (rows 3 to be-1) ----
        for (3..be) |r| {
            surf.writeCell(0, @intCast(r), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = self.border_style });
            surf.writeCell(re, @intCast(r), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = self.border_style });
        }

        // ---- Bottom border ----
        surf.writeCell(0, be, .{ .char = .{ .grapheme = "╰", .width = 1 }, .style = self.border_style });
        for (1..re) |c| {
            surf.writeCell(@intCast(c), be, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.border_style });
        }
        surf.writeCell(re, be, .{ .char = .{ .grapheme = "╯", .width = 1 }, .style = self.border_style });

        return surf;
    }
};
