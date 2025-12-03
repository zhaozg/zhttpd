const std = @import("std");

/// Bounded ring buffer for async log messages
/// Provides thread-safe enqueue/dequeue with FIFO ordering
pub fn AsyncQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T,
        head: usize,
        tail: usize,
        count: usize,
        mutex: std.Thread.Mutex,
        not_empty: std.Thread.Condition,
        not_full: std.Thread.Condition,
        shutdown: bool,

        pub fn init() Self {
            return .{
                .buffer = undefined,
                .head = 0,
                .tail = 0,
                .count = 0,
                .mutex = .{},
                .not_empty = .{},
                .not_full = .{},
                .shutdown = false,
            };
        }

        /// Try to enqueue an item (non-blocking)
        /// Returns true if successful, false if queue is full
        pub fn tryEnqueue(self: *Self, item: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count >= capacity) {
                return false;
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.count += 1;
            self.not_empty.signal();
            return true;
        }

        /// Enqueue an item (blocking if queue is full)
        pub fn enqueue(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count >= capacity and !self.shutdown) {
                self.not_full.wait(&self.mutex);
            }

            if (self.shutdown) return;

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.count += 1;
            self.not_empty.signal();
        }

        /// Dequeue an item (blocking if queue is empty)
        /// Returns null if queue is shutdown and empty
        pub fn dequeue(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == 0 and !self.shutdown) {
                self.not_empty.wait(&self.mutex);
            }

            if (self.count == 0 and self.shutdown) {
                return null;
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            self.not_full.signal();
            return item;
        }

        /// Try to dequeue an item (non-blocking)
        /// Returns null if queue is empty
        pub fn tryDequeue(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count == 0) {
                return null;
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            self.not_full.signal();
            return item;
        }

        /// Signal shutdown and wake all waiting threads
        pub fn signalShutdown(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.shutdown = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        /// Get current queue size
        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }

        /// Check if queue is empty
        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count == 0;
        }
    };
}

test "AsyncQueue basic operations" {
    const testing = std.testing;

    var queue = AsyncQueue(u32, 4).init();

    // Test enqueue
    try testing.expect(queue.tryEnqueue(1));
    try testing.expect(queue.tryEnqueue(2));
    try testing.expect(queue.len() == 2);

    // Test dequeue
    try testing.expectEqual(@as(?u32, 1), queue.tryDequeue());
    try testing.expectEqual(@as(?u32, 2), queue.tryDequeue());
    try testing.expect(queue.isEmpty());
}

test "AsyncQueue full queue" {
    const testing = std.testing;

    var queue = AsyncQueue(u32, 2).init();

    try testing.expect(queue.tryEnqueue(1));
    try testing.expect(queue.tryEnqueue(2));
    try testing.expect(!queue.tryEnqueue(3)); // Should fail when full

    _ = queue.tryDequeue();
    try testing.expect(queue.tryEnqueue(3)); // Should succeed after dequeue
}
