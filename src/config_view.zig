const std = @import("std");
const vaxis = @import("vaxis");
const Serial = @import("serial.zig");
const ser_utils = @import("serial");
const Logger = @import("log.zig");
const DropDown = @import("dropdown.zig").DropDown;

const vxfw = vaxis.vxfw;

const Allocator = std.mem.Allocator;

pub const ConfigModel = struct {
    port_dropdown: DropDown,
    baudrate_dropdown: DropDown,
    databits_dropdown: DropDown,
    parity_dropdown: DropDown,
    stopbits_dropdown: DropDown,
    ip_dropdown: DropDown,
    net_mode_dropdown: DropDown,
    input: vxfw.TextField,
    temp: []const u8 = "",
    is_ip_valid: bool = false,

    dropdowns: [5]*DropDown = undefined,

    button: vxfw.Button = .{
        .label = "Open",
        .onClick = ConfigModel.connectOrDisconnect,
    },

    is_stream_open: bool = false,
    index_ser: usize = 0,
    index_tcp: usize = 0,
    at_button: bool = true,

    userdata: *anyopaque,

    allocator: Allocator,
    state: State = .Serial,

    const State = enum {
        Serial,
        Ip,
    };

    pub const size = vxfw.Size{ .width = 22, .height = 10 };

    pub fn deinit(self: *ConfigModel) void {
        self.port_dropdown.deinit(self.allocator);
        self.baudrate_dropdown.deinit(self.allocator);
        self.databits_dropdown.deinit(self.allocator);
        self.parity_dropdown.deinit(self.allocator);
        self.stopbits_dropdown.deinit(self.allocator);
        self.ip_dropdown.deinit(self.allocator);
        self.net_mode_dropdown.deinit(self.allocator);
    }

    fn validateIpInput(ptr: ?*anyopaque, event: *vxfw.EventContext, buffer: []const u8) anyerror!void {
        _ = event;
        const self: *ConfigModel = @ptrCast(@alignCast(ptr));

        _ = std.net.Address.parseIpAndPort(buffer) catch {
            self.is_ip_valid = false;
            return;
        };
        self.is_ip_valid = true;
    }

    fn connectOrDisconnect(ptr: ?*anyopaque, event: *vxfw.EventContext) anyerror!void {
        const self: *ConfigModel = @ptrCast(@alignCast(ptr));
        const tui: *@import("tui.zig").Tui = @ptrCast(@alignCast(self.userdata));

        if (self.is_stream_open) return tui.closeStream();

        if (self.state == .Serial) {
            const port = self.port_dropdown.list.items[self.port_dropdown.list_view.cursor];

            try tui.openStream(.{ .ser_cfg = .{
                .port = port.text,
                .baudrate = @enumFromInt(try std.fmt.parseInt(u32, self.baudrate_dropdown.list.items[self.baudrate_dropdown.list_view.cursor].text[1..], 10)),
            } });
        } else {
            if (self.is_ip_valid) {
                const address = try std.net.Address.parseIpAndPort(self.input.previous_val);

                if (self.ip_dropdown.list_view.cursor == 0)
                    try tui.openStream(.{ .net_cfg = .{ .addr = address, .mode = .TCP } });
            }
        }

        event.consumeAndRedraw();
        return;
    }

    pub fn widget(self: *ConfigModel) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = ConfigModel.typeErasedEventHandler,
            .drawFn = ConfigModel.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *ConfigModel = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn enumerateSerialPorts(self: *ConfigModel) !void {
        var com_port_iter = try ser_utils.list();

        for (self.port_dropdown.list.items) |text| {
            self.allocator.free(text.text);
        }
        self.port_dropdown.list.clearRetainingCapacity();

        while (try com_port_iter.next()) |com_port| {
            try self.port_dropdown.list.append(self.allocator, vxfw.Text{
                .text = try self.allocator.dupe(u8, com_port.display_name),
            });
        }
    }

    pub fn handleEvent(self: *ConfigModel, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                self.dropdowns[0] = &self.port_dropdown;
                self.dropdowns[1] = &self.baudrate_dropdown;
                self.dropdowns[2] = &self.databits_dropdown;
                self.dropdowns[3] = &self.parity_dropdown;
                self.dropdowns[4] = &self.stopbits_dropdown;

                for (self.dropdowns) |dd| {
                    dd.list_view.children.builder.userdata = dd;
                }

                self.port_dropdown.description = "PORT:";
                self.baudrate_dropdown.description = "BAUD:";
                self.databits_dropdown.description = "DBIT:";
                self.parity_dropdown.description = " PAR:";
                self.stopbits_dropdown.description = "SBIT:";

                self.ip_dropdown.description = "Mode:";
                self.ip_dropdown.list_view.children.builder.userdata = &self.ip_dropdown;

                inline for (std.meta.fields(Serial.Baudrates)) |field| {
                    try self.baudrate_dropdown.list.append(self.allocator, vxfw.Text{ .text = try ctx.alloc.dupe(u8, field.name) });
                }

                inline for (std.meta.fields(ser_utils.WordSize)) |field| {
                    try self.databits_dropdown.list.append(self.allocator, vxfw.Text{ .text = try ctx.alloc.dupe(u8, field.name) });
                }
                self.databits_dropdown.list_view.cursor = @intCast(self.databits_dropdown.list.items.len - 1);

                inline for (std.meta.fields(ser_utils.Parity)) |field| {
                    try self.parity_dropdown.list.append(self.allocator, vxfw.Text{ .text = try ctx.alloc.dupe(u8, field.name) });
                }

                inline for (std.meta.fields(ser_utils.StopBits)) |field| {
                    try self.stopbits_dropdown.list.append(self.allocator, vxfw.Text{ .text = try ctx.alloc.dupe(u8, field.name) });
                }

                inline for (std.meta.fields(@import("net_stream.zig").NetMode)) |field| {
                    try self.ip_dropdown.list.append(self.allocator, vxfw.Text{ .text = try ctx.alloc.dupe(u8, field.name) });
                }

                self.input.onChange = ConfigModel.validateIpInput;
                self.input.userdata = self;

                self.button.userdata = self;
                return self.button.handleEvent(ctx, .focus_in);
            },
            .key_press => |key| {
                if (self.state == .Serial) {
                    if (self.dropdowns[self.index_ser].is_expanded) {
                        return self.dropdowns[self.index_ser].widget().handleEvent(ctx, event);
                    }

                    if (self.at_button and key.matches(vaxis.Key.enter, .{})) {
                        return self.button.handleEvent(ctx, event);
                    }

                    if (key.matches(vaxis.Key.tab, .{})) {
                        // serial to udp view
                        self.state = .Ip;
                        ctx.consumeAndRedraw();
                        return;
                    }

                    if (key.matches('j', .{})) {
                        if (self.at_button == true) {
                            self.at_button = false;
                            try self.button.handleEvent(ctx, .focus_out);
                            return try self.dropdowns[self.index_ser].handleEvent(ctx, .focus_in);
                        }

                        const prev_index = self.index_ser;
                        self.index_ser += if (self.index_ser < self.dropdowns.len - 1) 1 else 0;
                        try self.dropdowns[prev_index].handleEvent(ctx, .focus_out);
                        return self.dropdowns[self.index_ser].handleEvent(ctx, .focus_in);
                    }
                    if (key.matches('k', .{})) {
                        const prev_index = self.index_ser;
                        self.index_ser -= if (self.index_ser > 0) 1 else 0;

                        if (self.index_ser == prev_index) {
                            self.at_button = true;
                            try self.button.handleEvent(ctx, .focus_in);
                            return try self.dropdowns[self.index_ser].handleEvent(ctx, .focus_out);
                        } else {
                            try self.dropdowns[prev_index].handleEvent(ctx, .focus_out);
                            return self.dropdowns[self.index_ser].handleEvent(ctx, .focus_in);
                        }
                    }

                    return self.dropdowns[self.index_ser].widget().handleEvent(ctx, event);
                } else {
                    // next

                    if (key.matches(vaxis.Key.tab, .{})) {
                        // serial to udp view
                        self.state = .Serial;
                        ctx.consumeAndRedraw();
                        return;
                    }

                    if (self.index_tcp == 1 and self.ip_dropdown.is_expanded) {
                        return self.ip_dropdown.handleEvent(ctx, event);
                    }

                    try self.distributeEvent(ctx, .focus_out);

                    if (key.matches('j', .{})) {
                        self.index_tcp += if (self.index_tcp == 2) 0 else 1;
                        try self.distributeEvent(ctx, .focus_in);
                        return ctx.consumeAndRedraw();
                    }

                    if (key.matches('k', .{})) {
                        self.index_tcp -= if (self.index_tcp == 0) 0 else 1;
                        try self.distributeEvent(ctx, .focus_in);
                        return ctx.consumeAndRedraw();
                    }

                    return self.distributeEvent(ctx, event);
                }
            },
            else => {},
        }

        return;
    }

    fn distributeEvent(self: *ConfigModel, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        if (self.state == .Serial) {} else {
            switch (self.index_tcp) {
                0 => {
                    return self.button.handleEvent(ctx, event);
                },
                1 => {
                    return self.ip_dropdown.handleEvent(ctx, event);
                },
                2 => {
                    return self.input.handleEvent(ctx, event);
                },
                else => unreachable,
            }
        }
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *ConfigModel = @ptrCast(@alignCast(ptr));

        if (self.state == .Ip) {
            return try self.drawIpConfigView(ctx);
        }

        var height: u16 = 1;
        var width: u16 = 0;

        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = 6 },
            .surface = try self.button.widget().draw(ctx.withConstraints(.{ .width = 1, .height = 1 }, .{ .width = 8, .height = 1 })),
        });

        try children.append(ctx.arena, .{
            .origin = .{ .row = height, .col = 1 },
            .surface = try self.port_dropdown.widget().draw(ctx),
        });
        height += children.getLast().surface.size.height;
        width = @max(width, children.getLast().surface.size.width);

        try children.append(ctx.arena, .{
            .origin = .{ .row = height, .col = 1 },
            .surface = try self.baudrate_dropdown.widget().draw(ctx),
        });
        height += children.getLast().surface.size.height;
        width = @max(width, children.getLast().surface.size.width);

        try children.append(ctx.arena, .{
            .origin = .{ .row = height, .col = 1 },
            .surface = try self.databits_dropdown.widget().draw(ctx),
        });
        height += children.getLast().surface.size.height;
        width = @max(width, children.getLast().surface.size.width);

        try children.append(ctx.arena, .{
            .origin = .{ .row = height, .col = 1 },
            .surface = try self.parity_dropdown.widget().draw(ctx),
        });
        height += children.getLast().surface.size.height;
        width = @max(width, children.getLast().surface.size.width);

        try children.append(ctx.arena, .{
            .origin = .{ .row = height, .col = 1 },
            .surface = try self.stopbits_dropdown.widget().draw(ctx),
        });
        height += children.getLast().surface.size.height;
        width = @max(width, children.getLast().surface.size.width);

        if (self.is_stream_open) {
            self.button.label = "Close";
            self.button.style.default = .{ .reverse = true, .blink = true };
            self.button.style.focus = .{ .reverse = true, .blink = true };
        } else {
            self.button.label = "Open";
            self.button.style.default = .{ .reverse = true, .blink = true };
            self.button.style.focus = .{ .reverse = true, .blink = true };
        }

        return .{
            .size = .{ .width = width, .height = height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    fn drawIpConfigView(self: *ConfigModel, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        var height: u16 = 1;

        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = 7 },
            .surface = try self.button.widget().draw(ctx.withConstraints(.{ .width = 1, .height = 1 }, .{ .width = 8, .height = 1 })),
        });

        try children.append(ctx.arena, .{
            .origin = .{ .row = 1, .col = 6 },
            .surface = try (self.ip_dropdown.widget().draw(ctx.withConstraints(ctx.min, .{ .width = 8, .height = 2 }))),
        });

        height += children.getLast().surface.size.height;

        try children.append(ctx.arena, .{
            .origin = .{
                .row = 1 + children.getLast().surface.size.height,
                .col = 0,
            },
            .surface = try (vxfw.Border{ .child = self.input.widget(), .style = .{
                .blink = if (self.index_tcp == 1) true else false,
                .fg = if (self.is_ip_valid) .{ .index = 2 } else .{ .index = 1 },
            } }).widget().draw(ctx.withConstraints(ctx.min, .{ .width = ConfigModel.size.width, .height = ConfigModel.size.height })),
        });

        height += children.getLast().surface.size.height;

        if (self.is_stream_open) {
            self.button.label = "Close";
            self.button.style.focus = .{ .reverse = true, .blink = true };
        } else {
            self.button.label = "Open";
            self.button.style.focus = .{ .reverse = true, .blink = true };
        }

        return .{
            .size = .{ .width = children.getLast().surface.size.width, .height = height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }
};
