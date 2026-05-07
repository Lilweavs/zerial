const std = @import("std");
const vaxis = @import("vaxis");
const Serial = @import("serial.zig");
const CircularArray = @import("circular_array.zig");

const Record = @import("record.zig");

const Allocator = std.mem.Allocator;

const vxfw = vaxis.vxfw;

const event_queue = @import("tui.zig").eventQueue();

pub const State = enum {
    Ascii,
    Binary,
};

pub const StreamView = struct {
    index: usize = 0,
    hex_index: usize = 0,

    records: []Record = &.{},
    snap: SnapMode = .Bot,
    // view_state: State = .Ascii,

    top: usize = 0,
    bot: usize = 0,

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

    pub fn handleEvent(self: *StreamView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('j', .{})) {
                    self.index += 1;
                    if (self.index > self.records.len -| 1) {
                        self.index = self.records.len -| 1;
                        _ = try event_queue.tryPush(.ScrollDown);
                    }
                }
                if (key.matches('k', .{})) {
                    if (self.index == 0) {
                        _ = try event_queue.tryPush(.ScrollUp);
                    } else self.index -= 1;
                }
                if (key.matches('j', .{ .shift = true })) {
                    self.index += 5;
                    if (self.index > self.records.len -| 1) {
                        self.index = self.records.len -| 1;
                        for (0..5) |_| _ = try event_queue.tryPush(.ScrollDown);
                    }
                }
                if (key.matches('k', .{ .shift = true })) {
                    if (self.index >= 5) {
                        self.index -= 5;
                    } else {
                        for (0..5) |_| _ = try event_queue.tryPush(.ScrollUp);
                        self.index = 0;
                    }
                }
                if (key.matches('>', .{})) {
                    // self.snap = .Bot;
                }
                if (key.matches('<', .{})) {
                    // self.snap = .Top;
                }
                if (key.matches('y', .{})) {
                    // if (self.data.size != 0) {
                    // try ctx.cmds.append(ctx.alloc, .{ .copy_to_clipboard = self.data.get(self.index).text });
                    // }
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

        // std.log.info("size: {d}\n", .{self.records.len});
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
                        .reverse = self.index == i,
                    },
                }).widget().draw(ctx),
            });

            row += children.getLast().surface.size.height;
            col = 0;
        }

        return .{
            .size = .{ .width = ctx.max.width.?, .height = @intCast(row) },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }
};
