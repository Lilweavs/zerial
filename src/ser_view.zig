const std = @import("std");
const vaxis = @import("vaxis");
const Serial = @import("serial.zig");
const ser_utils = @import("serial");
const DropDown = @import("dropdown.zig").DropDown;
const HorizontalLine = @import("HorizontalLine.zig").HorizontalLine;

const vxfw = vaxis.vxfw;

const TuiEvent = @import("tui.zig");
const EventQueue = TuiEvent.EventQueue;

const Allocator = std.mem.Allocator;

const ddoffset = 5;

pub const SerView = struct {
    port_dropdown: DropDown = .{},
    baudrate_dropdown: DropDown = .{},
    databits_dropdown: DropDown = .{},
    parity_dropdown: DropDown = .{},
    stopbits_dropdown: DropDown = .{},
    is_stream_open: bool = false,

    button: vxfw.Button = .{
        .label = "Open",
        .onClick = connectOrDisconnect,
    },

    index: usize = 0,

    event_queue: *EventQueue,
    allocator: Allocator,

    pub fn enumerateSerialPorts(_: *SerView, io: std.Io, allocator: Allocator) ![][]const u8 {
        var com_port_iter = try ser_utils.list(io);
        var list: std.ArrayList([]const u8) = .empty;
        while (try com_port_iter.next()) |com_port| {
            try list.append(allocator, try allocator.dupe(u8, com_port.display_name));
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn deinitPortDropdown(self: *SerView, allocator: Allocator) void {
        if (self.port_dropdown.list.len > 0) {
            for (self.port_dropdown.list) |ptr| allocator.free(ptr);
            allocator.free(self.port_dropdown.list);
        }
        self.port_dropdown.list = &.{};
    }

    pub fn deinit(self: *SerView, allocator: Allocator) void {
        self.port_dropdown.deinit(allocator);
        self.baudrate_dropdown.deinit(allocator);
        self.databits_dropdown.deinit(allocator);
        self.parity_dropdown.deinit(allocator);
        self.stopbits_dropdown.deinit(allocator);
    }

    pub fn getSerialConfigOptions(self: *SerView) Serial.Options {
        return .{
            .port = self.port_dropdown.list[self.port_dropdown.index],
            .baudrate = std.meta.stringToEnum(Serial.Baudrates, self.baudrate_dropdown.list[self.baudrate_dropdown.index]).?,
            .parity = std.meta.stringToEnum(ser_utils.Parity, self.parity_dropdown.list[self.parity_dropdown.index]).?,
            .stopbits = std.meta.stringToEnum(ser_utils.StopBits, self.stopbits_dropdown.list[self.stopbits_dropdown.index]).?,
            .wordsize = std.meta.stringToEnum(ser_utils.WordSize, self.databits_dropdown.list[self.databits_dropdown.index]).?,
        };
    }

    fn connectOrDisconnect(ptr: ?*anyopaque, _: *vxfw.EventContext) anyerror!void {
        const self: *SerView = @ptrCast(@alignCast(ptr.?));
        try self.event_queue.push(.StreamOpenClose);
    }

    pub fn widget(self: *SerView) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = SerView.typeErasedEventHandler,
            .drawFn = SerView.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *SerView = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn handleDropdown(self: *SerView, ctx: *vxfw.EventContext, key: vaxis.Key, dd: *DropDown) !void {
        if (dd.is_expanded) {
            try dd.handleEvent(ctx, .{ .key_press = key });
        } else {
            if (key.matches(vaxis.Key.enter, .{})) {
                dd.is_expanded = true;
            }
            self.moveFocus(ctx, key);
        }
    }

    pub fn handleEvent(self: *SerView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                var list: std.ArrayList([]const u8) = .empty;

                inline for (std.meta.fields(Serial.Baudrates)) |field| {
                    try list.append(self.allocator, try self.allocator.dupe(u8, field.name));
                }
                self.baudrate_dropdown.list = try list.toOwnedSlice(self.allocator);

                inline for (std.meta.fields(ser_utils.WordSize)) |field| {
                    try list.append(self.allocator, try self.allocator.dupe(u8, field.name));
                }
                self.databits_dropdown.list = try list.toOwnedSlice(self.allocator);
                self.databits_dropdown.index = 3;

                inline for (std.meta.fields(ser_utils.Parity)) |field| {
                    try list.append(self.allocator, try self.allocator.dupe(u8, field.name));
                }
                self.parity_dropdown.list = try list.toOwnedSlice(self.allocator);

                inline for (std.meta.fields(ser_utils.StopBits)) |field| {
                    try list.append(self.allocator, try self.allocator.dupe(u8, field.name));
                }
                self.stopbits_dropdown.list = try list.toOwnedSlice(self.allocator);

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
                    1 => try self.handleDropdown(ctx, key, &self.port_dropdown),
                    2 => try self.handleDropdown(ctx, key, &self.baudrate_dropdown),
                    3 => try self.handleDropdown(ctx, key, &self.databits_dropdown),
                    4 => try self.handleDropdown(ctx, key, &self.parity_dropdown),
                    5 => try self.handleDropdown(ctx, key, &self.stopbits_dropdown),
                    else => {},
                }
            },
            else => {},
        }
    }

    fn moveFocus(self: *SerView, ctx: *vxfw.EventContext, key: vaxis.Key) void {
        _ = ctx;
        if (key.matches('j', .{})) {
            self.index = @min(self.index + 1, @as(usize, 5));
        }
        if (key.matches('k', .{})) {
            self.index -|= 1;
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            _ = self.event_queue.tryPush(.Home) catch @panic("not handled");
        }
    }

    fn setSelected(self: *SerView) void {
        self.button.focused = false;
        self.port_dropdown.is_focused = false;
        self.baudrate_dropdown.is_focused = false;
        self.databits_dropdown.is_focused = false;
        self.parity_dropdown.is_focused = false;
        self.stopbits_dropdown.is_focused = false;
        switch (self.index) {
            0 => self.button.focused = true,
            1 => self.port_dropdown.is_focused = true,
            2 => self.baudrate_dropdown.is_focused = true,
            3 => self.databits_dropdown.is_focused = true,
            4 => self.parity_dropdown.is_focused = true,
            5 => self.stopbits_dropdown.is_focused = true,
            else => {},
        }
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *SerView = @ptrCast(@alignCast(ptr));

        var height: u16 = 2; // fields start at row 2 (row 0 button, row 1 horizontal line)
        var width: u16 = 0;

        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        self.setSelected();

        self.button.label = if (self.is_stream_open) "Close" else "Open";

        // Port
        {
            const label = try (vxfw.Text{ .text = "PORT " }).widget().draw(ctx);
            const dd = try (vxfw.Border{ .child = self.port_dropdown.widget() }).widget().draw(ctx);
            try children.append(ctx.arena, .{ .origin = .{ .row = height + 1, .col = 0 }, .surface = label });
            try children.append(ctx.arena, .{ .origin = .{ .row = height, .col = ddoffset }, .surface = dd });
            width = @max(width, label.size.width, ddoffset + dd.size.width);
            height += dd.size.height;
        }

        // Baud
        {
            const label = try (vxfw.Text{ .text = "BAUD " }).widget().draw(ctx);
            const dd = try (vxfw.Border{ .child = self.baudrate_dropdown.widget() }).widget().draw(ctx);
            try children.append(ctx.arena, .{ .origin = .{ .row = height + 1, .col = 0 }, .surface = label });
            try children.append(ctx.arena, .{ .origin = .{ .row = height, .col = ddoffset }, .surface = dd });
            width = @max(width, label.size.width, ddoffset + dd.size.width);
            height += dd.size.height;
        }

        // Databits
        {
            const label = try (vxfw.Text{ .text = "DBIT " }).widget().draw(ctx);
            const dd = try (vxfw.Border{ .child = self.databits_dropdown.widget() }).widget().draw(ctx);
            try children.append(ctx.arena, .{ .origin = .{ .row = height + 1, .col = 0 }, .surface = label });
            try children.append(ctx.arena, .{ .origin = .{ .row = height, .col = ddoffset }, .surface = dd });
            width = @max(width, label.size.width, ddoffset + dd.size.width);
            height += dd.size.height;
        }

        // Parity
        {
            const label = try (vxfw.Text{ .text = " PAR " }).widget().draw(ctx);
            const dd = try (vxfw.Border{ .child = self.parity_dropdown.widget() }).widget().draw(ctx);
            try children.append(ctx.arena, .{ .origin = .{ .row = height + 1, .col = 0 }, .surface = label });
            try children.append(ctx.arena, .{ .origin = .{ .row = height, .col = ddoffset }, .surface = dd });
            width = @max(width, label.size.width, ddoffset + dd.size.width);
            height += dd.size.height;
        }

        // Stopbits
        {
            const label = try (vxfw.Text{ .text = "SBIT " }).widget().draw(ctx);
            const dd = try (vxfw.Border{ .child = self.stopbits_dropdown.widget() }).widget().draw(ctx);
            try children.append(ctx.arena, .{ .origin = .{ .row = height + 1, .col = 0 }, .surface = label });
            try children.append(ctx.arena, .{ .origin = .{ .row = height, .col = ddoffset }, .surface = dd });
            width = @max(width, label.size.width, ddoffset + dd.size.width);
            height += dd.size.height;
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
