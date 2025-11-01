const std = @import("std");
const vaxis = @import("vaxis");
const Serial = @import("serial.zig");
const CircularArray = @import("circular_array.zig");

const Allocator = std.mem.Allocator;

const vxfw = vaxis.vxfw;

pub const Record = struct {
    text: []const u8,
    time: i64,
    rxOrTx: RxOrTx,

    pub const RxOrTx = enum {
        RX,
        TX,
    };
};

pub const State = enum {
    Ascii,
    Binary,
};

pub const SerialMonitor = struct {
    index: usize = 0,
    hex_index: usize = 0,

    allocator: Allocator,
    data: CircularArray.CircularArray(Record),
    hex_data: CircularArray.CircularArray(Record),
    snap_to_bottom: bool = false,
    view_state: State = .Ascii,

    pub fn widget(self: *SerialMonitor) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = SerialMonitor.typeErasedEventHandler,
            .drawFn = SerialMonitor.typeErasedDrawFn,
        };
    }

    pub fn deinit(self: *SerialMonitor) void {
        defer self.data.deinit();
        defer self.hex_data.deinit();
        while (self.data.popOrNull()) |ptr| {
            self.allocator.free(ptr.text);
        }
        while (self.hex_data.popOrNull()) |ptr| {
            self.allocator.free(ptr.text);
        }
    }

    pub fn append(self: *SerialMonitor, record: Record) !void {
        // check for old ascii data
        if (self.data.getPtrOrNull(self.data.size -| 1)) |tail| {
            if (record.rxOrTx != tail.rxOrTx) {
                self.data.append(record);
            } else {
                // check if we need to append to row
                const text = tail.text;
                if (text[text.len - 1] != '\n') {
                    tail.text = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ text, record.text });
                    self.allocator.free(text);
                } else {
                    self.data.append(record);
                }
            }
        } else {
            self.data.append(record);
        }

        // check for old binary data
        if (self.hex_data.getPtrOrNull(self.hex_data.size -| 1)) |tail| {
            if (record.rxOrTx != tail.rxOrTx) {
                try self.splitRecordHex(record, 32);
            } else {
                const hex = tail.text;
                if (hex.len < 32) {
                    const remaining = 32 - hex.len;

                    if (record.text.len >= remaining) {
                        tail.text = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ hex, record.text[0..remaining] });
                        try self.splitRecordHex(.{
                            .rxOrTx = record.rxOrTx,
                            .text = record.text[remaining..],
                            .time = record.time,
                        }, 32);
                    } else {
                        tail.text = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ hex, record.text });
                    }
                    self.allocator.free(hex);
                } else {
                    try self.splitRecordHex(record, 32);
                }
            }
        } else {
            try self.splitRecordHex(record, 32);
        }
    }

    fn splitRecordHex(self: *SerialMonitor, record: Record, hex_width: usize) !void {
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
        const self: *SerialMonitor = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *SerialMonitor, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('j', .{})) {
                    self.index += 1;
                    self.hex_index += 1;
                    ctx.consumeAndRedraw();
                }
                if (key.matches('k', .{})) {
                    self.index -|= 1;
                    self.hex_index -|= 1;
                    ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
        return;
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *SerialMonitor = @ptrCast(@alignCast(ptr));

        var surfaces = try std.ArrayList(vxfw.SubSurface).initCapacity(ctx.arena, ctx.max.height.?);

        var total_height: usize = 0;

        const max_height = ctx.max.height.?;

        if (self.snap_to_bottom) {
            self.index = self.data.size -| max_height;
            self.hex_index = self.hex_data.size -| max_height;
            self.snap_to_bottom = false;
        }

        self.index = @min(self.index, self.data.size -| 1);
        self.hex_index = @min(self.hex_index, self.hex_data.size -| 1);

        const start = if (self.view_state == .Ascii) self.index else self.hex_index;
        const end = if (self.view_state == .Ascii) self.data.size else self.hex_data.size;

        for (start..end) |i| {
            if (total_height >= max_height) {
                break;
            }

            var model: ModelRow = .{
                .record = if (self.view_state == .Ascii) self.data.get(i) else self.hex_data.get(i),
                .state = self.view_state,
            };

            try surfaces.append(ctx.arena, vxfw.SubSurface{
                .origin = .{ .row = @intCast(total_height), .col = 0 },
                .surface = try model.widget().draw(ctx.withConstraints(ctx.min, .{ .width = ctx.max.width.? - 3, .height = 1 })),
            });

            total_height += surfaces.getLast().surface.size.height;
        }

        return .{
            .size = .{ .width = ctx.max.width.?, .height = @max(ctx.max.height.?, @as(u16, @intCast(total_height))) },
            .widget = self.widget(),
            .buffer = &.{},
            .children = surfaces.items[0..total_height],
        };
    }
};

pub const ModelRow = struct {
    record: Record,
    state: State,
    wrap_lines: bool = true,

    pub fn widget(self: *ModelRow) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = ModelRow.typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *ModelRow = @ptrCast(@alignCast(ptr));

        var milliseconds = @mod(self.record.time, std.time.ms_per_day);
        const hours = @abs(@divFloor(milliseconds, std.time.ms_per_hour));
        milliseconds = @mod(milliseconds, std.time.ms_per_hour);
        const mins = @abs(@divFloor(milliseconds, std.time.ms_per_min));
        milliseconds = @mod(milliseconds, std.time.ms_per_min);
        const seconds = @abs(@divFloor(milliseconds, std.time.ms_per_s));
        milliseconds = @mod(milliseconds, std.time.ms_per_s);

        var children = std.ArrayList(vxfw.SubSurface).empty;

        var width: u16 = 0;

        var text: []const u8 = undefined;
        if (self.state == .Binary) {
            const tmp = try ctx.arena.alloc(u8, self.record.text.len * 3);
            for (0..self.record.text.len) |i| {
                if (std.fmt.bufPrint(tmp[i * 3 .. (i + 1) * 3], "{X:0>2} ", .{self.record.text[i]})) |_| {} else |_| {}
            }
            text = tmp;
        } else {
            text = self.record.text;
        }

        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try (vxfw.Text{
                .text = try std.fmt.allocPrint(ctx.arena, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} >", .{ hours, mins, seconds, @as(usize, @intCast(milliseconds)) }),
                .style = .{
                    .fg = .{
                        .rgb = .{ 255, 255, 0 },
                    },
                },
            }).widget().draw(ctx),
        });

        width += children.getLast().surface.size.width;

        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = width },
            .surface = try (vxfw.Text{
                .text = text,
                .softwrap = false,
                .style = .{
                    .fg = .{
                        .index = if (self.record.rxOrTx == .RX) 7 else 6,
                    },
                },
            }).widget().draw(ctx),
        });

        width += children.getLast().surface.size.width;

        // 0: black
        // 1: red
        // 2: green
        // 3: orange?
        // 4: blue
        // 5: purple
        // 6: cyan
        // 7: default/white
        // 8: grey
        // 9: ligher red or mod 8

        return .{
            .size = .{ .width = width, .height = 1 },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }
};
