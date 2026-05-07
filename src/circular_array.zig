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

        const Iterator = struct {
            head: usize,
            tail: usize,
            capacity: usize,
            data: []T,

            pub fn next(it: *Iterator) ?T {
                if (it.head == it.tail) return null;
                const head = it.head;
                it.head = (it.head + 1) % it.capacity;
                return it.data[head];
            }
        };

        pub fn iterator(a: *const Self, offset: usize) Iterator {
            const head = if (offset > a.size) a.head else (a.tail + (a.capacity - offset)) % a.capacity;
            return .{
                .head = head,
                .tail = a.tail,
                .data = a.data,
                .capacity = a.capacity,
            };
        }

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

        /// returns T if an object was overwritten
        pub fn pushDropOldest(self: *Self, item: T) ?T {
            // if we are full we need to deallocate the previous record
            var stale: ?T = null;
            if (self.capacity == self.size) {
                stale = self.data[self.head];
                self.incrementHead();
            }

            self.data[self.tail] = item;
            self.incrementTail();
            return stale;
        }

        fn incrementHead(self: *Self) void {
            self.head = (self.head + 1) % self.capacity;
            self.size -= 1;
        }

        fn incrementTail(self: *Self) void {
            self.tail = (self.tail + 1) % self.capacity;
            self.size += 1;
        }

        pub fn popOrNull(self: *Self) ?T {
            if (self.size == 0) return null;
            const prev_head = self.head;
            self.incrementHead();
            return self.data[prev_head];
        }

        pub fn get(self: Self, index: usize) T {
            std.debug.assert(index < self.size);
            return self.data[(self.head + index) % self.capacity];
        }

        pub fn getOrNull(self: Self, index: usize) ?T {
            if (self.size == 0 or index >= self.size) return null;
            return self.get(index);
        }

        pub fn getPtr(self: Self, index: usize) *T {
            std.debug.assert(index < self.size);
            return &self.data[(self.head + index) % self.capacity];
        }

        pub fn getPtrOrNull(self: Self, index: usize) ?*T {
            if (self.size == 0 or index >= self.size) return null;
            return self.getPtr(index);
        }
    };
}
