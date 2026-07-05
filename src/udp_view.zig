const std = @import("std");
const vaxis = @import("vaxis");
const HorizontalLine = @import("HorizontalLine.zig").HorizontalLine;

const vxfw = vaxis.vxfw;

const TuiEvent = @import("tui.zig");
const EventQueue = TuiEvent.EventQueue;

const Allocator = std.mem.Allocator;

const ddoffset = 5;

pub const UdpView = struct {
    ip_input: vxfw.TextField = undefined,
    port_input: vxfw.TextField = undefined,
    is_ip_valid: bool = false,
    is_port_valid: bool = false,
    is_stream_open: bool = false,

    button: vxfw.Button = .{
        .label = "Open",
        .onClick = connectOrDisconnect,
    },

    index: usize = 0,
    editing: bool = false,

    event_queue: *EventQueue,
    allocator: Allocator,

    fn onIpChange(ptr: ?*anyopaque, _: *vxfw.EventContext, text: []const u8) anyerror!void {
        const self: *UdpView = @ptrCast(@alignCast(ptr));
        self.is_ip_valid = if (std.Io.net.IpAddress.parseLiteral(text)) |_| true else |_| false;
    }

    fn onPortChange(ptr: ?*anyopaque, _: *vxfw.EventContext, text: []const u8) anyerror!void {
        const self: *UdpView = @ptrCast(@alignCast(ptr));
        self.is_port_valid = if (std.fmt.parseInt(u16, text, 10)) |port| port > 0 else |_| false;
    }

    fn connectOrDisconnect(ptr: ?*anyopaque, _: *vxfw.EventContext) anyerror!void {
        const self: *UdpView = @ptrCast(@alignCast(ptr.?));
        try self.event_queue.push(.StreamOpenClose);
    }

    pub fn deinit(self: *UdpView) void {
        self.ip_input.deinit();
        self.port_input.deinit();
    }

    pub fn widget(self: *UdpView) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = UdpView.typeErasedEventHandler,
            .drawFn = UdpView.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *UdpView = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *UdpView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                self.ip_input.userdata = self;
                self.ip_input.onChange = onIpChange;
                self.port_input.userdata = self;
                self.port_input.onChange = onPortChange;
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
                        if (self.editing) {
                            if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.escape, .{})) {
                                self.editing = false;
                                try self.ip_input.handleEvent(ctx, .focus_out);
                                try ctx.requestFocus(self.widget());
                                return ctx.consumeAndRedraw();
                            }
                            try self.ip_input.handleEvent(ctx, event);
                            return ctx.consumeAndRedraw();
                        } else {
                            if (key.matches(vaxis.Key.enter, .{})) {
                                self.editing = true;
                                try self.ip_input.handleEvent(ctx, .focus_in);
                                try ctx.requestFocus(self.ip_input.widget());
                                return ctx.consumeAndRedraw();
                            }
                            self.moveFocus(ctx, key);
                        }
                    },
                    2 => {
                        if (self.editing) {
                            if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.escape, .{})) {
                                self.editing = false;
                                try self.port_input.handleEvent(ctx, .focus_out);
                                try ctx.requestFocus(self.widget());
                                return ctx.consumeAndRedraw();
                            }
                            try self.port_input.handleEvent(ctx, event);
                            return ctx.consumeAndRedraw();
                        } else {
                            if (key.matches(vaxis.Key.enter, .{})) {
                                self.editing = true;
                                try self.port_input.handleEvent(ctx, .focus_in);
                                try ctx.requestFocus(self.port_input.widget());
                                return ctx.consumeAndRedraw();
                            }
                            self.moveFocus(ctx, key);
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn moveFocus(self: *UdpView, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        if (key.matches('j', .{})) {
            self.index = @min(self.index + 1, @as(usize, 2));
            return ctx.consumeAndRedraw();
        }
        if (key.matches('k', .{})) {
            self.index -|= 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            _ = self.event_queue.tryPush(.Home) catch @panic("not handled");
            return ctx.consumeAndRedraw();
        }
    }

    fn setSelected(self: *UdpView) void {
        self.button.focused = false;
        self.ip_input.style = .{};
        self.port_input.style = .{};
        switch (self.index) {
            0 => self.button.focused = true,
            1 => {
                if (!self.editing) self.ip_input.style = .{ .reverse = true };
            },
            2 => {
                if (!self.editing) self.port_input.style = .{ .reverse = true };
            },
            else => {},
        }
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *UdpView = @ptrCast(@alignCast(ptr));

        var height: u16 = 2; // fields start at row 2 (row 0 button, row 1 horizontal line)
        var width: u16 = 0;

        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        self.setSelected();

        self.button.label = if (self.is_stream_open) "Close" else "Open";

        // Address input: label and input on the same row
        {
            const label = try (vxfw.Text{ .text = "ADDR " }).widget().draw(ctx);
            const input_width: u16 = 20;
            var input = try self.ip_input.widget().draw(ctx.withConstraints(
                .{ .width = 0, .height = 1 },
                .{ .width = input_width, .height = 1 },
            ));
            if (self.index != 2 or !self.editing) input.cursor = null;
            try children.append(ctx.arena, .{ .origin = .{ .row = height, .col = 0 }, .surface = label });
            try children.append(ctx.arena, .{ .origin = .{ .row = height, .col = ddoffset }, .surface = input });
            width = @max(width, label.size.width, ddoffset + input.size.width);
            height += 1;
        }

        // Port input: label and input on the same row
        {
            const label = try (vxfw.Text{ .text = "PORT " }).widget().draw(ctx);
            const input_width: u16 = 6;
            var input = try self.port_input.widget().draw(ctx.withConstraints(
                .{ .width = 0, .height = 1 },
                .{ .width = input_width, .height = 1 },
            ));
            if (self.index != 3 or !self.editing) input.cursor = null;
            try children.append(ctx.arena, .{ .origin = .{ .row = height, .col = 0 }, .surface = label });
            try children.append(ctx.arena, .{ .origin = .{ .row = height, .col = ddoffset }, .surface = input });
            width = @max(width, label.size.width, ddoffset + input.size.width);
            height += 1;
        }

        // Button at row 0, centered
        {
            const surf = try self.button.widget().draw(ctx.withConstraints(.{}, .{ .width = 8, .height = 1 }));
            const btn_x = (width -| surf.size.width) / 2;
            try children.append(ctx.arena, .{ .origin = .{ .row = 0, .col = btn_x }, .surface = surf });
            width = @max(width, surf.size.width);
        }

        // HorizontalLine at row 1, spanning full content width
        try children.append(ctx.arena, .{
            .origin = .{ .row = 1, .col = 0 },
            .surface = try (HorizontalLine{}).widget().draw(
                ctx.withConstraints(.{}, .{ .width = width, .height = 1 }),
            ),
        });

        return .{
            .size = .{ .width = width, .height = height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }
};
