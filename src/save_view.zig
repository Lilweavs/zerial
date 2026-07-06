const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;
const vxfw = vaxis.vxfw;
const history_format = @import("history_format.zig");

const TuiEvent = @import("tui.zig");
const EventQueue = TuiEvent.EventQueue;

const SaveSubMode = enum {
    Buttons,
    Input,
};

pub const SaveView = struct {
    input: vxfw.TextField,
    current_file: ?[]const u8 = null,
    save_sub_mode: SaveSubMode = .Buttons,
    save_button_idx: u2 = 0,
    event_queue: *EventQueue,
    allocator: Allocator,
    appdata_dir: []const u8 = &.{},
    history_list: *std.ArrayList([]const u8),

    pub fn helpText() []const []const u8 {
        return &.{
            "",
            " Save History:",
            "   Tab/Right     Switch button",
            "   Left          Focus Save",
            "   Enter         Confirm",
            "   Escape        Close",
        };
    }

    pub fn deinit(self: *SaveView, allocator: Allocator) void {
        self.input.deinit();
        if (self.current_file) |f| allocator.free(f);
    }

    pub fn widget(self: *SaveView) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *SaveView = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *SaveView = @ptrCast(@alignCast(ptr));
        return self.drawFn(ctx);
    }

    pub fn handleEvent(self: *SaveView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                self.input.userdata = self;
                self.input.onSubmit = onSaveSubmit;
            },
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    _ = try self.event_queue.tryPush(.Home);
                    return;
                }

                if (self.save_sub_mode == .Buttons) {
                    if (key.matches(vaxis.Key.enter, .{})) {
                        switch (self.save_button_idx) {
                            0 => {
                                const name = self.current_file orelse "command_history.hist";
                                self.saveHistory(ctx.io, name) catch {};
                                _ = try self.event_queue.tryPush(.Home);
                                return ctx.consumeAndRedraw();
                            },
                            1 => {
                                self.save_sub_mode = .Input;
                                self.input.clearAndFree();
                                self.input.onSubmit = onSaveSubmit;
                                try ctx.requestFocus(self.input.widget());
                                return ctx.consumeAndRedraw();
                            },
                            else => {},
                        }
                    }
                    if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.right, .{})) {
                        self.save_button_idx = if (self.save_button_idx == 0) 1 else 0;
                        return ctx.consumeAndRedraw();
                    }
                    if (key.matches(vaxis.Key.left, .{})) {
                        self.save_button_idx = 0;
                        return ctx.consumeAndRedraw();
                    }
                    return ctx.consumeAndRedraw();
                } else {
                    return self.input.handleEvent(ctx, event);
                }
            },
            .paste => {
                try self.input.insertSliceAtCursor(event.paste);
                return ctx.consumeAndRedraw();
            },
            else => {},
        }
    }

    fn drawFn(self: *SaveView, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        var width: u16 = 0;
        var surface_height: u16 = 1;

        if (self.save_sub_mode == .Buttons) {
            const focus_style = vaxis.Style{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } };
            const btn_width: u16 = 21;

            const path_text = if (self.current_file) |file|
                try std.fmt.allocPrint(ctx.arena, "file: {s}", .{file})
            else
                "";
            const path_width: u16 = @intCast(path_text.len);
            const total_width = @max(btn_width, path_width);

            const btn_pad = (total_width -| btn_width) / 2;
            var col = btn_pad;

            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = col },
                .surface = try (vxfw.Text{ .text = " " }).widget().draw(ctx),
            });
            col += 1;

            if (self.save_button_idx == 0) {
                try children.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = col },
                    .surface = try (vxfw.Text{ .text = "[ Save ]", .style = focus_style }).widget().draw(ctx),
                });
            } else {
                try children.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = col },
                    .surface = try (vxfw.Text{ .text = "[ Save ]" }).widget().draw(ctx),
                });
            }
            col += "[ Save ]".len;

            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = col },
                .surface = try (vxfw.Text{ .text = "  " }).widget().draw(ctx),
            });
            col += 2;

            if (self.save_button_idx == 1) {
                try children.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = col },
                    .surface = try (vxfw.Text{ .text = "[ Save As ]", .style = focus_style }).widget().draw(ctx),
                });
            } else {
                try children.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = col },
                    .surface = try (vxfw.Text{ .text = "[ Save As ]" }).widget().draw(ctx),
                });
            }
            col += "[ Save As ]".len;

            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = col },
                .surface = try (vxfw.Text{ .text = " " }).widget().draw(ctx),
            });
            col += 1;

            if (path_width > 0) {
                const path_col = (total_width -| path_width) / 2;
                try children.append(ctx.arena, .{
                    .origin = .{ .row = 1, .col = path_col },
                    .surface = try (vxfw.Text{ .text = path_text, .style = vaxis.Style{ .fg = .{ .index = 8 } } }).widget().draw(ctx),
                });
            }

            width = total_width;
            surface_height = if (self.current_file != null) 2 else 1;
        } else {
            const label = "save as:";
            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try (vxfw.Text{ .text = label }).widget().draw(ctx),
            });
            width += children.items[children.items.len - 1].surface.size.width;
            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = width },
                .surface = try self.input.widget().draw(ctx.withConstraints(ctx.min, .{ .width = ctx.max.width.? - (width + 4), .height = 1 })),
            });
            width += children.getLast().surface.size.width;
        }

        return .{
            .size = .{ .width = width, .height = surface_height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    fn saveHistory(self: *SaveView, io: std.Io, name: []const u8) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.appdata_dir, name });
        defer self.allocator.free(path);
        var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        for (self.history_list.*.items) |line| {
            const escaped = try history_format.escapeForFile(line, self.allocator);
            defer self.allocator.free(escaped);
            _ = try file.writeStreamingAll(io, escaped);
            _ = try file.writeStreamingAll(io, "\r\n");
        }
        try self.writeMetadata(io, name);
        if (self.current_file) |f| self.allocator.free(f);
        self.current_file = try self.allocator.dupe(u8, name);
    }

    fn writeMetadata(self: *SaveView, io: std.Io, name: []const u8) !void {
        const meta_path = try std.fs.path.join(self.allocator, &.{ self.appdata_dir, "last_hist.txt" });
        defer self.allocator.free(meta_path);
        var file = try std.Io.Dir.createFileAbsolute(io, meta_path, .{});
        defer file.close(io);
        _ = try file.writeStreamingAll(io, name);
    }

    pub fn onSaveSubmit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const self: *SaveView = @ptrCast(@alignCast(ptr));
        if (str.len == 0) return;
        const name_with_ext = try std.fmt.allocPrint(self.allocator, "{s}.hist", .{str});
        defer self.allocator.free(name_with_ext);
        self.saveHistory(ctx.io, name_with_ext) catch {};
        self.input.clearAndFree();
        _ = try self.event_queue.tryPush(.Home);
        return ctx.consumeAndRedraw();
    }
};
