const std = @import("std");
const vaxis = @import("vaxis");
const DropDown = @import("dropdown.zig").DropDown;
const Allocator = std.mem.Allocator;
const HorizontalLine = @import("HorizontalLine.zig").HorizontalLine;
const vxfw = vaxis.vxfw;
const fuzz = @import("fuzzy.zig");
const StreamManager = @import("stream_manager.zig");

const TuiEvent = @import("tui.zig");
const EventQueue = TuiEvent.EventQueue;

pub const SendView = struct {
    input: vxfw.TextField,
    show_history: bool = false,
    paste_active: bool = false,
    saved_on_submit: ?*const fn (?*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,
    drop_down: DropDown = .{},
    history_list: std.ArrayList([]const u8) = .empty,
    filtered_list: std.ArrayList([]const u8) = .empty,
    event_queue: *EventQueue,
    write_queue: *vaxis.Queue(StreamManager.SendMessage, 8) = undefined,
    delimiter: Delimiter = .CRLF,
    allocator: Allocator,
    appdata_dir: []const u8 = &.{},

    const Delimiter = enum(u2) {
        NONE,
        CRLF,
        CR,
        LF,
    };

    fn getDelimiter(d: Delimiter) []const u8 {
        return switch (d) {
            .NONE => "",
            .CRLF => "\r\n",
            .CR => "\r",
            .LF => "\n",
        };
    }

    fn isLineTerminator(s: []const u8) bool {
        return std.mem.eql(u8, s, "\r\n") or std.mem.eql(u8, s, "\r") or std.mem.eql(u8, s, "\n");
    }

    pub fn deinit(self: *SendView, allocator: Allocator) void {
        self.input.deinit();
        self.drop_down.list = &.{};
        self.drop_down.deinit(allocator);
        for (self.history_list.items) |h| allocator.free(h);
        self.history_list.deinit(allocator);
        self.filtered_list.deinit(allocator);
    }

    pub fn widget(self: *SendView) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = SendView.typeErasedCaptureHandler,
            .eventHandler = SendView.typeErasedEventHandler,
            .drawFn = SendView.typeErasedDrawFn,
        };
    }

    fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *SendView = @ptrCast(@alignCast(ptr));
        return self.captureEvent(ctx, event);
    }

    fn captureEvent(self: *SendView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (self.show_history) {
                    if (key.matches('d', .{ .ctrl = true }) or
                        key.matches('j', .{ .ctrl = true }) or
                        key.matches('k', .{ .ctrl = true }) or
                        key.matches('e', .{ .ctrl = true }) or
                        key.matches(vaxis.Key.enter, .{ .ctrl = true }) or
                        key.matches(vaxis.Key.enter, .{ .shift = true }))
                    {
                        return self.handleEvent(ctx, event);
                    }
                }
            },
            else => {},
        }
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *SendView = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *SendView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                self.input.userdata = self;
                self.input.onChange = onChange;
                self.input.onSubmit = onSendSubmit;
                self.drop_down.list = self.history_list.items;
            },
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    _ = try self.event_queue.tryPush(.Home);
                    return;
                }

                if (key.matches(vaxis.Key.backspace, .{ .ctrl = true })) {
                    self.input.deleteToStart();
                }

                if (key.matches('h', .{ .ctrl = true })) {
                    self.show_history = !self.show_history;
                    return ctx.consumeAndRedraw();
                }

                if (key.matches('l', .{ .ctrl = true })) {
                    var i: u2 = @intFromEnum(self.delimiter);
                    i +%= 1;
                    self.delimiter = @enumFromInt(i);
                    return ctx.consumeAndRedraw();
                }

                if (key.matches(vaxis.Key.enter, .{ .shift = true })) {
                    try self.input.insertSliceAtCursor("\n");
                    return ctx.consumeAndRedraw();
                }

                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.paste_active) {
                        try self.input.insertSliceAtCursor("\n");
                        return ctx.consumeAndRedraw();
                    }
                }

                if (key.matches(vaxis.Key.up, .{})) {
                    self.moveCursorUp();
                    return ctx.consumeAndRedraw();
                }

                if (key.matches(vaxis.Key.down, .{})) {
                    self.moveCursorDown();
                    return ctx.consumeAndRedraw();
                }

                if (!self.show_history and key.matches('j', .{ .ctrl = true })) {
                    try self.input.insertSliceAtCursor("\n");
                    return ctx.consumeAndRedraw();
                }

                if (self.show_history) {
                    if (key.matches(vaxis.Key.enter, .{ .ctrl = true }) or key.matches(vaxis.Key.enter, .{ .alt = true })) {
                        if (self.drop_down.list.len == 0) return;

                        const to_send = self.drop_down.list[self.drop_down.index];

                        _ = try self.write_queue.tryPush(.{ .bytes = try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ to_send, getDelimiter(self.delimiter) }) });
                        return ctx.consumeAndRedraw();
                    }

                    if (key.matches('d', .{ .ctrl = true })) {
                        if (self.drop_down.list.len == 0) return;

                        const idx = self.drop_down.index;
                        self.allocator.free(self.history_list.items[idx]);
                        _ = self.history_list.orderedRemove(idx);

                        self.filtered_list.clearRetainingCapacity();
                        for (self.history_list.items) |h| {
                            try self.filtered_list.append(self.allocator, h);
                        }
                        self.drop_down.list = self.filtered_list.items;

                        if (self.drop_down.index >= self.history_list.items.len) {
                            self.drop_down.index = self.history_list.items.len -| 1;
                        }
                        return ctx.consumeAndRedraw();
                    }

                    if (key.matches('j', .{ .ctrl = true })) {
                        return try self.drop_down.handleEvent(ctx, .{ .key_press = .{ .codepoint = 'j' } });
                    }
                    if (key.matches('k', .{ .ctrl = true })) {
                        return try self.drop_down.handleEvent(ctx, .{ .key_press = .{ .codepoint = 'k' } });
                    }

                    if (key.matches('e', .{ .ctrl = true })) {
                        if (self.drop_down.list.len == 0) return;

                        const item = self.drop_down.list[self.drop_down.index];
                        self.input.clearAndFree();
                        try self.input.insertSliceAtCursor(item);

                        return ctx.consumeAndRedraw();
                    }

                    return self.input.handleEvent(ctx, event);
                } else {
                    defer {
                        if (key.matches(vaxis.Key.enter, .{})) {
                            self.input.deleteToStart();
                        }
                    }
                    return self.input.handleEvent(ctx, event);
                }
            },
            .paste_start => {
                self.paste_active = true;
                self.saved_on_submit = self.input.onSubmit;
                self.input.onSubmit = null;
                return ctx.consumeAndRedraw();
            },
            .paste_end => {
                self.paste_active = false;
                if (self.saved_on_submit) |cb| self.input.onSubmit = cb;
                self.saved_on_submit = null;
                return ctx.consumeAndRedraw();
            },
            .paste => {
                try self.input.insertSliceAtCursor(event.paste);
                return ctx.consumeAndRedraw();
            },
            else => {},
        }

        return;
    }

    pub fn onSendSubmit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const self: *SendView = @ptrCast(@alignCast(ptr));

        const already_in_history = for (self.history_list.items) |h| {
            if (std.mem.eql(u8, h, str)) break true;
        } else false;

        if (!already_in_history and str.len > 1 and !isLineTerminator(str)) {
            try self.history_list.append(self.allocator, try self.allocator.dupe(u8, str));

            self.filtered_list.clearRetainingCapacity();
            for (self.history_list.items) |h| {
                try self.filtered_list.append(self.allocator, h);
            }
            self.drop_down.list = self.filtered_list.items;
        }

        if (std.mem.indexOfScalar(u8, str, '\n') != null) {
            var lines = std.mem.splitScalar(u8, str, '\n');
            var line_count: usize = 0;
            while (lines.next()) |line| {
                if (line_count > 0) {
                    _ = try self.write_queue.tryPush(.{ .delay_ms = 5 });
                }
                const bytes = try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ line, getDelimiter(self.delimiter) });
                if (!try self.write_queue.tryPush(.{ .bytes = bytes })) {
                    ctx.alloc.free(bytes);
                }
                line_count += 1;
            }
        } else {
            const bytes = try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ str, getDelimiter(self.delimiter) });
            if (!try self.write_queue.tryPush(.{ .bytes = bytes })) {
                ctx.alloc.free(bytes);
            }
        }

        return ctx.consumeAndRedraw();
    }

    pub fn onChange(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const self: *SendView = @ptrCast(@alignCast(ptr));
        self.filtered_list.clearRetainingCapacity();
        if (str.len > 0) {
            const filtered = try fuzz.fuzzList(self.history_list.items, str, ctx.alloc);
            defer ctx.alloc.free(filtered);
            for (filtered) |item| {
                try self.filtered_list.append(self.allocator, self.history_list.items[item.idx]);
            }
        } else {
            for (self.history_list.items) |h| {
                try self.filtered_list.append(self.allocator, h);
            }
        }

        self.drop_down.list = self.filtered_list.items;

        return ctx.consumeAndRedraw();
    }

    fn moveCursorUp(self: *SendView) void {
        const first = self.input.buf.firstHalf();
        const cursor = first.len;

        var current_line_start: usize = 0;
        for (0..first.len) |i| {
            if (first[first.len - 1 - i] == '\n') {
                current_line_start = first.len - i;
                break;
            }
        }
        if (current_line_start == 0) return;

        const col = cursor - current_line_start;

        var prev_line_start: usize = 0;
        const search_end = current_line_start -| 1;
        for (0..search_end) |i| {
            const idx = search_end - 1 - i;
            if (first[idx] == '\n') {
                prev_line_start = idx + 1;
                break;
            }
        }

        const prev_line_len = (current_line_start -| 1) -| prev_line_start;
        const target_col = @min(col, prev_line_len);
        const new_pos = prev_line_start + target_col;

        if (new_pos < cursor) {
            self.input.buf.moveGapLeft(cursor - new_pos);
        }
    }

    fn moveCursorDown(self: *SendView) void {
        const first = self.input.buf.firstHalf();
        const second = self.input.buf.secondHalf();
        const cursor = first.len;

        var current_line_start: usize = 0;
        for (0..first.len) |i| {
            if (first[first.len - 1 - i] == '\n') {
                current_line_start = first.len - i;
                break;
            }
        }
        const col = cursor - current_line_start;

        var current_line_end = first.len + second.len;
        for (second, 0..) |c, i| {
            if (c == '\n') {
                current_line_end = first.len + i;
                break;
            }
        }
        if (current_line_end == first.len + second.len) return;

        const next_line_start = current_line_end + 1;

        var next_line_end = first.len + second.len;
        for (second[next_line_start - first.len ..], 0..) |c, i| {
            if (c == '\n') {
                next_line_end = next_line_start + i;
                break;
            }
        }

        const next_line_len = next_line_end - next_line_start;
        const target_col = @min(col, next_line_len);
        const new_pos = next_line_start + target_col;

        if (new_pos > cursor) {
            self.input.buf.moveGapRight(new_pos - cursor);
        }
    }

    fn inputLineCount(self: *SendView) usize {
        return 1 +
            std.mem.count(u8, self.input.buf.firstHalf(), "\n") +
            std.mem.count(u8, self.input.buf.secondHalf(), "\n");
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *SendView = @ptrCast(@alignCast(ptr));

        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        var width: u16 = 0;

        const line_count = self.inputLineCount();
        const input_height: u16 = @max(@as(u16, @intCast(@min(line_count, 10))), 1);

        const label = "send:";
        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try (vxfw.Text{ .text = label }).widget().draw(ctx),
        });

        width += children.items[children.items.len - 1].surface.size.width;

        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = width },
            .surface = try self.input.widget().draw(ctx.withConstraints(.{ .width = 0, .height = input_height }, .{ .width = ctx.max.width.? - (width + 4), .height = input_height })),
        });
        width += children.getLast().surface.size.width;

        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = width },
            .surface = try (vxfw.Text{
                .text = @tagName(self.delimiter),
                .style = .{
                    .fg = .{
                        .index = 1,
                    },
                },
            }).widget().draw(ctx),
        });
        width += children.getLast().surface.size.width;

        var height = input_height;

        if (self.show_history) {
            try children.append(ctx.arena, .{ .origin = .{ .row = height, .col = 0 }, .surface = try (HorizontalLine{ .label = .{ .text = "History", .alignment = .center } }).widget().draw(ctx.withConstraints(ctx.min, ctx.max)) });
            height += 1;

            self.drop_down.is_expanded = true;

            try children.append(ctx.arena, .{
                .origin = .{ .row = height, .col = 0 },
                .surface = try self.drop_down.widget().draw(ctx),
            });

            height += children.getLast().surface.size.height;
        }

        return .{
            .size = .{ .width = width, .height = height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }
};
