const std = @import("std");
const vaxis = @import("vaxis");
const DropDown = @import("dropdown.zig").DropDown;
const Allocator = std.mem.Allocator;
const vxfw = vaxis.vxfw;

const TuiEvent = @import("tui.zig");
const EventQueue = TuiEvent.EventQueue;

pub const LoadView = struct {
    file_dropdown: DropDown = .{},
    hist_files: [][]const u8 = &.{},
    event_queue: *EventQueue,
    allocator: Allocator,
    appdata_dir: []const u8 = &.{},
    history_list: *[][]const u8,

    pub fn deinit(self: *LoadView, allocator: Allocator) void {
        self.file_dropdown.list = &.{};
        self.file_dropdown.deinit(allocator);
        for (self.hist_files) |f| allocator.free(f);
        allocator.free(self.hist_files);
    }

    pub fn widget(self: *LoadView) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *LoadView = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *LoadView = @ptrCast(@alignCast(ptr));
        return self.drawFn(ctx);
    }

    pub fn handleEvent(self: *LoadView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{})) {
                    _ = try self.event_queue.tryPush(.Home);
                    return;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.file_dropdown.list.len == 0) return;
                    const name = self.file_dropdown.list[self.file_dropdown.index];
                    self.loadHistory(ctx.io, name) catch {};
                    _ = try self.event_queue.tryPush(.Home);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('j', .{})) {
                    self.file_dropdown.index +|= 1;
                    if (self.file_dropdown.index >= self.file_dropdown.list.len)
                        self.file_dropdown.index = self.file_dropdown.list.len -| 1;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('k', .{})) {
                    self.file_dropdown.index -|= 1;
                    return ctx.consumeAndRedraw();
                }
                return ctx.consumeAndRedraw();
            },
            else => {},
        }
    }

    fn drawFn(self: *LoadView, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        self.file_dropdown.is_expanded = true;
        var file_surface = try self.file_dropdown.widget().draw(ctx);
        if (file_surface.size.width == 0) {
            file_surface = try (vxfw.Text{ .text = " (no saved histories) " }).widget().draw(ctx);
        }
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        try children.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = file_surface });
        return .{
            .size = .{ .width = file_surface.size.width, .height = file_surface.size.height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    pub fn listHistFiles(self: *LoadView, io: std.Io) !void {
        for (self.hist_files) |f| self.allocator.free(f);
        if (self.hist_files.len > 0) self.allocator.free(self.hist_files);

        var list: std.ArrayList([]const u8) = .empty;
        var dir = std.Io.Dir.openDirAbsolute(io, self.appdata_dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => {
                self.hist_files = try list.toOwnedSlice(self.allocator);
                return;
            },
            else => |err| return err,
        };
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, ".hist")) {
                try list.append(self.allocator, try self.allocator.dupe(u8, entry.name));
            }
        }
        self.hist_files = try list.toOwnedSlice(self.allocator);
        self.file_dropdown.list = self.hist_files;
    }

    fn loadHistory(self: *LoadView, io: std.Io, name: []const u8) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.appdata_dir, name });
        defer self.allocator.free(path);
        var dir = try std.Io.Dir.openDirAbsolute(io, self.appdata_dir, .{});
        defer dir.close(io);
        const data = try dir.readFileAlloc(io, name, self.allocator, @enumFromInt(1024 * 1024));
        defer self.allocator.free(data);

        var lines: std.ArrayList([]const u8) = .empty;
        var iter = std.mem.splitScalar(u8, data, '\n');
        while (iter.next()) |line| {
            if (line.len > 0) {
                try lines.append(self.allocator, try self.allocator.dupe(u8, line));
            }
        }
        for (self.history_list.*) |h| self.allocator.free(h);
        self.allocator.free(self.history_list.*);
        self.history_list.* = try lines.toOwnedSlice(self.allocator);
        try self.writeMetadata(io, name);
    }

    fn writeMetadata(self: *LoadView, io: std.Io, name: []const u8) !void {
        const meta_path = try std.fs.path.join(self.allocator, &.{ self.appdata_dir, "last_hist.txt" });
        defer self.allocator.free(meta_path);
        var file = try std.Io.Dir.createFileAbsolute(io, meta_path, .{});
        defer file.close(io);
        _ = try file.writeStreamingAll(io, name);
    }

    pub fn loadLastHistory(self: *LoadView, io: std.Io) !void {
        const meta_path = try std.fs.path.join(self.allocator, &.{ self.appdata_dir, "last_hist.txt" });
        defer self.allocator.free(meta_path);
        var appdata = std.Io.Dir.openDirAbsolute(io, self.appdata_dir, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => |err| return err,
        };
        defer appdata.close(io);
        const data = appdata.readFileAlloc(io, "last_hist.txt", self.allocator, @enumFromInt(4096)) catch |e| switch (e) {
            error.FileNotFound, error.NotDir, error.AccessDenied, error.NameTooLong => return,
            else => |err| return err,
        };
        defer self.allocator.free(data);
        const name = std.mem.trim(u8, data, &[_]u8{ '\n', '\r' });
        if (name.len > 0) {
            self.loadHistory(io, name) catch {};
        }
    }
};
