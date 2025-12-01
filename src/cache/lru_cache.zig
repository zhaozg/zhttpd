//! Generic Thread-Safe LRU Cache
//!
//! This module provides a generic thread-safe LRU (Least Recently Used) cache
//! implementation using Zig's standard library primitives.
//!
//! ## Features
//! - O(1) lookups via hash map
//! - LRU eviction via doubly-linked list
//! - Thread-safe with mutex protection
//! - Configurable max entries and optional TTL
//!
//! ## Usage
//! ```zig
//! const MyCache = LruCache([]const u8, MyValue);
//! var cache = MyCache.init(allocator, .{ .max_size = 1000 });
//! defer cache.deinit();
//!
//! try cache.put("key", value);
//! if (cache.getPtr("key")) |entry| {
//!     defer entry.release();
//!     // Use entry.value
//! }
//! ```

const std = @import("std");

/// Configuration for LRU cache
pub const CacheConfig = struct {
    /// Maximum number of entries
    max_size: usize = 10000,
    /// Default TTL in milliseconds (0 = no expiry)
    default_ttl_ms: i64 = 0,
};

/// Generic thread-safe LRU cache
pub fn LruCache(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        /// Node in the doubly-linked list
        pub const Node = struct {
            key: K,
            value: V,
            expires_ms: i64 = 0,
            prev: ?*Node = null,
            next: ?*Node = null,
        };

        /// Entry returned from get operations
        /// Must call release() when done to unlock the cache
        pub const Entry = struct {
            node: *Node,
            cache: *Self,

            pub fn release(self: *Entry) void {
                self.cache.mutex.unlock();
            }
        };

        /// Hash map for O(1) key lookups
        map: std.StringHashMap(*Node),
        /// Head of the LRU list (most recently used)
        head: ?*Node = null,
        /// Tail of the LRU list (least recently used)
        tail: ?*Node = null,
        /// Current number of entries
        count: usize = 0,
        /// Maximum number of entries
        max_size: usize,
        /// Default TTL in milliseconds
        default_ttl_ms: i64,
        /// Allocator for nodes
        allocator: std.mem.Allocator,
        /// Mutex for thread safety
        mutex: std.Thread.Mutex = .{},
        /// Optional context for cleanup callbacks
        context: Context,
        /// Cleanup callback for evicted values
        on_evict: ?*const fn (K, *V, Context) void = null,

        /// Initialize a new LRU cache
        pub fn init(allocator: std.mem.Allocator, config: CacheConfig, context: Context, on_evict: ?*const fn (K, *V, Context) void) Self {
            return Self{
                .map = std.StringHashMap(*Node).init(allocator),
                .allocator = allocator,
                .max_size = config.max_size,
                .default_ttl_ms = config.default_ttl_ms,
                .context = context,
                .on_evict = on_evict,
            };
        }

        /// Clean up and free all resources
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Free all nodes and their values
            var node = self.head;
            while (node) |n| {
                const next = n.next;
                // Call cleanup callback
                if (self.on_evict) |callback| {
                    callback(n.key, &n.value, self.context);
                }
                // Free the key (owned copy)
                self.allocator.free(n.key);
                // Free the node itself
                self.allocator.destroy(n);
                node = next;
            }
            self.map.deinit();
            self.head = null;
            self.tail = null;
            self.count = 0;
        }

        /// Check if an entry has expired
        fn isExpired(node: *Node) bool {
            if (node.expires_ms == 0) return false;
            return std.time.milliTimestamp() >= node.expires_ms;
        }

        /// Get entry by key and lock it for exclusive access
        /// Returns an Entry that must be released after use
        /// Returns null if not found or expired
        pub fn getEntry(self: *Self, key: K) ?Entry {
            self.mutex.lock();
            // Don't unlock here - caller must release

            if (self.map.get(key)) |node| {
                // Check expiration
                if (isExpired(node)) {
                    self.removeNodeLocked(node);
                    self.mutex.unlock();
                    return null;
                }
                // Move to front (most recently used)
                self.moveToFrontLocked(node);
                return Entry{
                    .node = node,
                    .cache = self,
                };
            }
            self.mutex.unlock();
            return null;
        }

        /// Get a pointer to the value, locking the cache
        /// Caller must call release() on the returned entry when done
        pub fn getPtr(self: *Self, key: K) ?struct { value: *V, entry: Entry } {
            if (self.getEntry(key)) |entry| {
                return .{ .value = &entry.node.value, .entry = entry };
            }
            return null;
        }

        /// Check if a key exists (does not update LRU order)
        pub fn contains(self: *Self, key: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.get(key)) |node| {
                return !isExpired(node);
            }
            return false;
        }

        /// Put a value into the cache with optional custom TTL
        pub fn putWithTtl(self: *Self, key: K, value: V, ttl_ms: ?i64) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const expires = if (ttl_ms) |ttl|
                if (ttl > 0) std.time.milliTimestamp() + ttl else 0
            else if (self.default_ttl_ms > 0)
                std.time.milliTimestamp() + self.default_ttl_ms
            else
                0;

            // Check if key already exists
            if (self.map.get(key)) |existing| {
                // Call cleanup callback for old value
                if (self.on_evict) |callback| {
                    callback(existing.key, &existing.value, self.context);
                }
                // Update existing entry
                existing.value = value;
                existing.expires_ms = expires;
                self.moveToFrontLocked(existing);
                return;
            }

            // Create new node
            const node = try self.allocator.create(Node);
            errdefer self.allocator.destroy(node);

            // Duplicate the key
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);

            node.* = Node{
                .key = owned_key,
                .value = value,
                .expires_ms = expires,
            };

            // Add to map
            try self.map.put(owned_key, node);

            // Add to front of list
            self.addToFrontLocked(node);
            self.count += 1;

            // Evict if necessary
            self.evictIfNeededLocked();
        }

        /// Put a value with default TTL
        pub fn put(self: *Self, key: K, value: V) !void {
            return self.putWithTtl(key, value, null);
        }

        /// Delete an entry by key
        pub fn del(self: *Self, key: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.get(key)) |node| {
                self.removeNodeLocked(node);
                return true;
            }
            return false;
        }

        /// Clear all entries
        pub fn clear(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var node = self.head;
            while (node) |n| {
                const next = n.next;
                if (self.on_evict) |callback| {
                    callback(n.key, &n.value, self.context);
                }
                self.allocator.free(n.key);
                self.allocator.destroy(n);
                node = next;
            }
            self.map.clearRetainingCapacity();
            self.head = null;
            self.tail = null;
            self.count = 0;
        }

        /// Get the current number of entries
        pub fn getCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }

        // Internal: Move a node to the front of the list (must hold mutex)
        fn moveToFrontLocked(self: *Self, node: *Node) void {
            if (self.head == node) return; // Already at front

            // Remove from current position
            if (node.prev) |prev| prev.next = node.next;
            if (node.next) |next| next.prev = node.prev;
            if (self.tail == node) self.tail = node.prev;

            // Add to front
            node.prev = null;
            node.next = self.head;
            if (self.head) |head| head.prev = node;
            self.head = node;
            if (self.tail == null) self.tail = node;
        }

        // Internal: Add a node to the front of the list (must hold mutex)
        fn addToFrontLocked(self: *Self, node: *Node) void {
            node.prev = null;
            node.next = self.head;
            if (self.head) |head| head.prev = node;
            self.head = node;
            if (self.tail == null) self.tail = node;
        }

        // Internal: Remove a node from the list and map (must hold mutex)
        fn removeNodeLocked(self: *Self, node: *Node) void {
            // Remove from list
            if (node.prev) |prev| prev.next = node.next;
            if (node.next) |next| next.prev = node.prev;
            if (self.head == node) self.head = node.next;
            if (self.tail == node) self.tail = node.prev;

            // Remove from map
            _ = self.map.remove(node.key);

            // Update count
            self.count -= 1;

            // Call cleanup callback
            if (self.on_evict) |callback| {
                callback(node.key, &node.value, self.context);
            }

            // Free resources
            self.allocator.free(node.key);
            self.allocator.destroy(node);
        }

        // Internal: Evict entries if over capacity (must hold mutex)
        fn evictIfNeededLocked(self: *Self) void {
            while (self.count > self.max_size and self.tail != null) {
                self.removeNodeLocked(self.tail.?);
            }
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "LruCache basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestCache = LruCache([]const u8, i32, void);
    var cache = TestCache.init(allocator, .{ .max_size = 3 }, {}, null);
    defer cache.deinit();

    // Test put and get
    try cache.put("key1", 100);
    try cache.put("key2", 200);
    try cache.put("key3", 300);

    try testing.expect(cache.contains("key1"));
    try testing.expect(cache.contains("key2"));
    try testing.expect(cache.contains("key3"));

    if (cache.getPtr("key1")) |result| {
        defer result.entry.release();
        try testing.expect(result.value.* == 100);
    } else {
        try testing.expect(false);
    }

    // Test non-existent key
    try testing.expect(!cache.contains("nonexistent"));
}

test "LruCache eviction" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestCache = LruCache([]const u8, i32, void);
    var cache = TestCache.init(allocator, .{ .max_size = 2 }, {}, null);
    defer cache.deinit();

    // Add 3 items to a cache with max size 2
    try cache.put("key1", 1);
    try cache.put("key2", 2);
    try cache.put("key3", 3);

    // key1 should be evicted (LRU)
    try testing.expect(!cache.contains("key1"));
    try testing.expect(cache.contains("key2"));
    try testing.expect(cache.contains("key3"));
}

test "LruCache deletion" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestCache = LruCache([]const u8, i32, void);
    var cache = TestCache.init(allocator, .{ .max_size = 10 }, {}, null);
    defer cache.deinit();

    try cache.put("key1", 1);
    try testing.expect(cache.contains("key1"));

    try testing.expect(cache.del("key1"));
    try testing.expect(!cache.contains("key1"));

    try testing.expect(!cache.del("nonexistent"));
}
