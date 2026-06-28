const std = @import("std");

const Record = @import("record.zig").Record;
const CircularArray = @import("circular_array.zig").CircularArray;
const RecordArray = CircularArray(Record);

const Allocator = std.mem.Allocator;

pub const RecordStore = struct {
    records: RecordArray,
    scroll_offset: usize,
    max_lines: usize,

    pub fn init(allocator: Allocator) !RecordStore {
        return .{
            .records = try RecordArray.initCapacity(allocator, 1024),
            .scroll_offset = 10,
            .max_lines = 1,
        };
    }

    pub fn deinit(self: *RecordStore, allocator: Allocator) void {
        while (self.records.popOrNull()) |r| {
            allocator.free(r.text);
        }
        self.records.deinit();
    }

    pub fn addRecord(self: *RecordStore, allocator: Allocator, record: Record) !void {
        if (self.records.getPtrOrNull(self.records.size -| 1)) |tail| {
            if (record.rxOrTx != tail.rxOrTx or tail.text[tail.text.len -| 1] == '\n') {
                if (self.records.pushDropOldest(record)) |r| allocator.free(r.text);
            } else {
                const merged = try std.fmt.allocPrint(allocator, "{s}{s}", .{ tail.text, record.text });
                allocator.free(tail.text);
                allocator.free(record.text);
                tail.text = merged;
            }
        } else {
            if (self.records.pushDropOldest(record)) |r| allocator.free(r.text);
        }
    }

    pub fn constrainOffset(self: *RecordStore) void {
        self.scroll_offset = @max(self.scroll_offset, @min(self.max_lines, self.records.size));
    }

    pub fn viewable(self: *RecordStore, arena: Allocator, height: usize) ![]Record {
        self.max_lines = height -| 5;
        self.constrainOffset();

        var list = try std.ArrayList(Record).initCapacity(arena, height);
        var iter = self.records.iterator(self.scroll_offset);
        for (0..height -| 5) |_| {
            const line = iter.next() orelse break;
            try list.append(arena, line);
        }
        return list.items;
    }

    pub fn scrollUp(self: *RecordStore) void {
        self.scroll_offset = @min(
            self.scroll_offset + 1,
            @max(self.records.size, self.records.size -| self.max_lines),
        );
    }

    pub fn scrollDown(self: *RecordStore) void {
        self.scroll_offset = @max(self.max_lines, self.scroll_offset -| 1);
    }

    pub fn pageUp(self: *RecordStore) void {
        self.scroll_offset = @min(
            self.scroll_offset + self.max_lines,
            @max(self.records.size, self.records.size -| self.max_lines),
        );
    }

    pub fn pageDown(self: *RecordStore) void {
        self.scroll_offset = @max(self.max_lines, self.scroll_offset -| self.max_lines);
    }
};
