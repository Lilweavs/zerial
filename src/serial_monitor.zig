const std = @import("std");
const vaxis = @import("vaxis");

const Record = @import("record.zig");

const Allocator = std.mem.Allocator;

const vxfw = vaxis.vxfw;

const TuiEvent = @import("tui.zig");
const EventQueue = TuiEvent.EventQueue;

pub const State = enum {
    Ascii,
    Binary,
};

pub const StreamView = struct {
    index: usize = 0,
    visual_mode: bool = false,
    visual_anchor: usize = 0,

    records: []Record = &.{},
    snap: SnapMode = .Bot,

    event_queue: *EventQueue,

    pub const SnapMode = enum {
        None,
        Top,
        Bot,
    };

    pub fn widget(self: *StreamView) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = StreamView.typeErasedEventHandler,
            .drawFn = StreamView.typeErasedDrawFn,
        };
    }

    fn splitRecordHex(self: *StreamView, record: Record, hex_width: usize) !void {
        var i: usize = 0;
        while (i + hex_width < record.text.len) : (i += hex_width) {
            self.hex_data.append(.{
                .rxOrTx = record.rxOrTx,
                .text = try std.fmt.allocPrint(self.allocator, "{s}", .{record.text[i .. i + hex_width]}),
                .time = record.time,
            });
        } else self.hex_data.append(.{
            .rxOrTx = record.rxOrTx,
            .text = try std.fmt.allocPrint(self.allocator, "{s}", .{record.text[i..]}),
            .time = record.time,
        });
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *StreamView = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn copySelection(self: *StreamView, ctx: *vxfw.EventContext) !void {
        if (self.records.len == 0) return;
        const start = @min(self.visual_anchor, self.index);
        const end = @max(self.visual_anchor, self.index) + 1;
        var total: usize = 0;
        for (self.records[start..end]) |r| total += r.text.len + 1;
        const buf = try ctx.alloc.alloc(u8, total);
        var off: usize = 0;
        for (self.records[start..end]) |r| {
            @memcpy(buf[off..][0..r.text.len], r.text);
            off += r.text.len;
            buf[off] = '\n';
            off += 1;
        }
        try ctx.copyToClipboard(buf[0..off]);
        ctx.alloc.free(buf);
    }

    pub fn handleEvent(self: *StreamView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('v', .{})) {
                    if (!self.visual_mode) {
                        self.visual_mode = true;
                        self.visual_anchor = self.index;
                    } else {
                        self.visual_mode = false;
                    }
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.escape, .{})) {
                    if (self.visual_mode) {
                        self.visual_mode = false;
                        return ctx.consumeAndRedraw();
                    }
                    return;
                }
                if (key.matches('j', .{})) {
                    self.index += 1;
                    if (self.index > self.records.len -| 1) {
                        self.index = self.records.len -| 1;
                        _ = try self.event_queue.tryPush(.ScrollDown);
                    }
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('k', .{})) {
                    if (self.index == 0) {
                        _ = try self.event_queue.tryPush(.ScrollUp);
                    } else self.index -= 1;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('j', .{ .shift = true })) {
                    self.index += 5;
                    if (self.index > self.records.len -| 1) {
                        self.index = self.records.len -| 1;
                        _ = try self.event_queue.tryPush(.PageDown);
                    }
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('k', .{ .shift = true })) {
                    if (self.index >= 5) {
                        self.index -= 5;
                    } else {
                        _ = try self.event_queue.tryPush(.PageUp);
                        self.index = 0;
                    }
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('y', .{})) {
                    if (self.visual_mode) {
                        try self.copySelection(ctx);
                    } else if (self.records.len > 0) {
                        try ctx.copyToClipboard(self.records[self.index].text);
                    }
                    return ctx.consumeAndRedraw();
                }
                ctx.consumeAndRedraw();
            },
            else => {},
        }
        return;
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *StreamView = @ptrCast(@alignCast(ptr));

        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        var col: i17 = 0;
        var row: i17 = 0;

        self.index = @min(self.index, self.records.len -| 1);
        if (self.visual_mode) self.visual_anchor = @min(self.visual_anchor, self.records.len -| 1);

        const sel_start = if (self.visual_mode) @min(self.visual_anchor, self.index) else self.index;
        const sel_end = if (self.visual_mode) @max(self.visual_anchor, self.index) else self.index;

        for (self.records, 0..) |record, i| {
            var milliseconds = @mod(record.time, std.time.ms_per_day);
            const hours = @abs(@divFloor(milliseconds, std.time.ms_per_hour));
            milliseconds = @mod(milliseconds, std.time.ms_per_hour);
            const mins = @abs(@divFloor(milliseconds, std.time.ms_per_min));
            milliseconds = @mod(milliseconds, std.time.ms_per_min);
            const seconds = @abs(@divFloor(milliseconds, std.time.ms_per_s));
            milliseconds = @mod(milliseconds, std.time.ms_per_s);

            const text = try ctx.arena.dupe(u8, record.text);

            try children.append(ctx.arena, .{
                .origin = .{ .row = row, .col = col },
                .surface = try (vxfw.Text{
                    .text = try std.fmt.allocPrint(
                        ctx.arena,
                        "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} >",
                        .{
                            hours, mins, seconds, @as(usize, @intCast(milliseconds)),
                        },
                    ),
                    .style = .{
                        .fg = .{
                            .rgb = .{ 255, 255, 0 },
                        },
                    },
                }).widget().draw(ctx),
            });

            col += children.getLast().surface.size.width;

            try children.append(ctx.arena, .{
                .origin = .{ .row = row, .col = col },
                .surface = try (vxfw.Text{
                    .text = text,
                    .softwrap = false,
                    .style = .{
                        .fg = .{
                            .index = if (record.rxOrTx == .RX) 7 else 6,
                        },
                        .reverse = i >= sel_start and i <= sel_end,
                    },
                }).widget().draw(ctx),
            });

            row += children.getLast().surface.size.height;
            col = 0;
        }

        return .{
            .size = .{ .width = ctx.max.width.?, .height = ctx.max.height.? },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }
};
