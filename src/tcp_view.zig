const std = @import("std");
const vaxis = @import("vaxis");
const HorizontalLine = @import("HorizontalLine.zig").HorizontalLine;

const vxfw = vaxis.vxfw;

const TuiEvent = @import("tui.zig");
const EventQueue = TuiEvent.EventQueue;

const Allocator = std.mem.Allocator;

const ddoffset = 5;

pub const TcpView = struct {
    ip_input: vxfw.TextField = undefined,
    is_ip_valid: bool = false,
    is_stream_open: bool = false,

    button: vxfw.Button = .{
        .label = "Open",
        .onClick = connectOrDisconnect,
    },

    index: usize = 0,

    event_queue: *EventQueue,
    allocator: Allocator,

    fn onIpChange(ptr: ?*anyopaque, _: *vxfw.EventContext, text: []const u8) anyerror!void {
        const self: *TcpView = @ptrCast(@alignCast(ptr));
        self.is_ip_valid = if (std.Io.net.IpAddress.parseLiteral(text)) |_| true else |_| false;
    }

    fn connectOrDisconnect(ptr: ?*anyopaque, _: *vxfw.EventContext) anyerror!void {
        const self: *TcpView = @ptrCast(@alignCast(ptr.?));
        if (!self.is_ip_valid) return;
        try self.event_queue.push(.StreamOpenClose);
    }

    pub fn deinit(self: *TcpView) void {
        self.ip_input.deinit();
    }

    pub fn widget(self: *TcpView) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = TcpView.typeErasedEventHandler,
            .drawFn = TcpView.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *TcpView = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *TcpView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                self.ip_input.userdata = self;
                self.ip_input.onChange = onIpChange;
                self.button.userdata = self;
                return self.button.handleEvent(ctx, .focus_in);
            },
            .key_press => |key| {
                switch (self.index) {
                    0 => {
                        if (key.matches(vaxis.Key.enter, .{})) {
                            return self.button.handleEvent(ctx, event);
                        }
                        self.moveFocus(ctx, key);
                    },
                    1 => {
                        try self.ip_input.handleEvent(ctx, event);
                        return ctx.consumeAndRedraw();
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn moveFocus(self: *TcpView, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        _ = ctx;
        if (key.matches('j', .{})) {
            self.index = @min(self.index + 1, @as(usize, 1));
        }
        if (key.matches('k', .{})) {
            self.index -|= 1;
        }
    }

    fn setSelected(self: *TcpView) void {
        self.button.focused = false;
        switch (self.index) {
            0 => self.button.focused = true,
            else => {},
        }
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *TcpView = @ptrCast(@alignCast(ptr));

        var height: u16 = 0;
        var width: u16 = 0;

        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        self.setSelected();

        self.button.label = if (self.is_stream_open) "Close" else "Open";

        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try self.button.widget().draw(ctx.withConstraints(.{}, .{ .width = 8, .height = 1 })),
        });
        height += children.getLast().surface.size.height;

        try children.append(ctx.arena, .{
            .origin = .{ .row = height, .col = 0 },
            .surface = try (HorizontalLine{}).widget().draw(
                ctx.withConstraints(.{}, .{ .width = 30, .height = 1 }),
            ),
        });
        height += 1;

        const label = "ADDR ";
        try children.append(ctx.arena, .{
            .origin = .{ .row = height + 1, .col = 0 },
            .surface = try (vxfw.Text{ .text = label }).widget().draw(ctx),
        });

        const input_width: u16 = 20;
        try children.append(ctx.arena, .{
            .origin = .{ .row = height, .col = ddoffset },
            .surface = try self.ip_input.widget().draw(ctx.withConstraints(
                .{ .width = 0, .height = 1 },
                .{ .width = input_width, .height = 1 },
            )),
        });

        const field_width = ddoffset + input_width;
        width = @max(width, field_width);
        height += 1;

        return .{
            .size = .{ .width = width, .height = height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }
};
