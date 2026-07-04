const std = @import("std");
const vaxis = @import("vaxis");

const SerView = @import("ser_view.zig").SerView;
const TcpView = @import("tcp_view.zig").TcpView;
const UdpView = @import("udp_view.zig").UdpView;
const BorderWithTab = @import("BorderWithTab.zig").BorderWithTab;

const vxfw = vaxis.vxfw;

const TuiEvent = @import("tui.zig");
const EventQueue = TuiEvent.EventQueue;

const Allocator = std.mem.Allocator;

pub const ConfigView = struct {
    ser_view: SerView,
    tcp_view: TcpView,
    udp_view: UdpView,

    ser_tcp_udp: BorderWithTab,
    ser_tcp_udp_tabs: [3]BorderWithTab.Tab,

    event_queue: *EventQueue,
    allocator: Allocator,

    pub fn widget(self: *ConfigView) vxfw.Widget {
        return self.ser_tcp_udp.widget();
    }

    pub fn handleEvent(self: *ConfigView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                try self.ser_view.handleEvent(ctx, event);
                try self.tcp_view.handleEvent(ctx, event);
                try self.udp_view.handleEvent(ctx, event);
            },
            else => {
                try self.ser_tcp_udp.handleEvent(ctx, event);
            },
        }
    }

    pub fn enumerateSerialPorts(self: *ConfigView, io: std.Io, allocator: Allocator) !void {
        self.ser_view.deinitPortDropdown(allocator);
        self.ser_view.port_dropdown.list = try self.ser_view.enumerateSerialPorts(io, allocator);
    }

    pub fn deinit(self: *ConfigView, allocator: Allocator) void {
        self.ser_view.deinit(allocator);
        self.tcp_view.deinit();
        self.udp_view.deinit();
    }
};
