const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn CircularArray(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        data: []T,
        capacity: usize = 0,
        head: usize = 0,
        tail: usize = 0,
        size: usize = 0,

        pub fn initCapacity(allocator: Allocator, max_size: usize) !Self {
            return .{
                .allocator = allocator,
                .data = try allocator.alloc(T, max_size),
                .capacity = max_size,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        pub fn getCapacity(self: Self) usize {
            return self.data.len;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.size = 0;
            self.head = 0;
            self.tail = 0;
        }

        pub fn append(self: *Self, item: T) void {
            // if we are full we need to deallocate the previous record
            if (self.capacity == self.size) {
                if (T == @import("serial_monitor.zig").Record) {
                    const stale_data = self.data[self.head];
                    self.allocator.free(stale_data.text);
                }
                self.increamentHead();
            }

            self.data[self.tail] = item;
            self.increamentTail();
        }

        fn increamentHead(self: *Self) void {
            self.head = (self.head + 1) % self.capacity;
            self.size -= 1;
        }

        fn increamentTail(self: *Self) void {
            self.tail = (self.tail + 1) % self.capacity;
            self.size += 1;
        }

        pub fn popOrNull(self: *Self) ?T {
            if (self.size == 0) return null;
            const prev_head = self.head;
            self.increamentHead();
            return self.data[prev_head];
        }

        pub fn get(self: Self, index: usize) T {
            return self.data[(self.head + index) % self.capacity];
        }

        pub fn getOrNull(self: Self, index: usize) ?T {
            if (self.size == 0) return null;
            return self.get(index);
        }

        pub fn getPtr(self: Self, index: usize) *T {
            return &self.data[(self.head + index) % self.capacity];
        }

        pub fn getPtrOrNull(self: Self, index: usize) ?*T {
            if (self.size == 0) return null;
            return self.getPtr(index);
        }
    };
}
