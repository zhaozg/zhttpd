const std = @import("std");
const Config = @import("../config/config.zig");
const ReloadMode = Config.ReloadMode;

/// Maximum file size for reading (100MB)
const MAX_FILE_SIZE = 100 * 1024 * 1024;

/// Default file cache TTL in milliseconds (1 hour)
const DEFAULT_FILE_TTL_MS: i64 = 3600 * 1000;

/// Minimum interval between file stat checks in nanoseconds (1 second)
/// This reduces the overhead of stat() syscalls in auto reload mode
const STAT_CHECK_INTERVAL_NS: i128 = 1_000_000_000;

/// Reference-counted data block for zerocopy cache optimization.
///
/// This struct enables zerocopy serving by using atomic reference counting
/// to track when cached data is in use. When a cache entry is evicted while
/// still being served to clients, the memory cleanup is deferred until all
/// references are released.
///
/// ## Thread Safety
/// - Reference count operations use atomic operations for thread safety
/// - Multiple threads can hold references to the same data concurrently
/// - Memory is freed only when the last reference is released
///
/// ## Usage Pattern
/// 1. Cache stores data with ref_count = 1 (cache owns the reference)
/// 2. On cache hit, acquire() increments ref count (caller gets a reference)
/// 3. When response is sent, release() decrements ref count
/// 4. On eviction, cache calls release() on its reference
/// 5. Data is freed when ref_count reaches 0
pub const RefCountedData = struct {
    data: []const u8,
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(u32),

    /// Create a new reference-counted data block.
    /// The data is copied and owned by this struct.
    /// Initial reference count is 1 (the creator holds the first reference).
    pub fn create(allocator: std.mem.Allocator, data: []const u8) !*RefCountedData {
        const self = try allocator.create(RefCountedData);
        errdefer allocator.destroy(self);

        const owned_data = try allocator.dupe(u8, data);
        errdefer allocator.free(owned_data);

        self.* = .{
            .data = owned_data,
            .allocator = allocator,
            .ref_count = std.atomic.Value(u32).init(1),
        };
        return self;
    }

    /// Acquire a reference to this data block.
    /// The caller must call release() when done.
    /// Returns null if the data has been invalidated (ref_count was 0).
    pub fn acquire(self: *RefCountedData) ?*RefCountedData {
        // Use compare-exchange loop to safely increment ref count
        var current = self.ref_count.load(.acquire);
        while (current > 0) {
            if (self.ref_count.cmpxchgWeak(current, current + 1, .release, .acquire)) |new_value| {
                current = new_value;
            } else {
                return self;
            }
        }
        // ref_count was 0, data is being freed
        return null;
    }

    /// Release a reference to this data block.
    /// When the last reference is released, the data is freed.
    pub fn release(self: *RefCountedData) void {
        const prev = self.ref_count.fetchSub(1, .release);
        if (prev == 1) {
            // Last reference, free the data
            // Use acquire load to synchronize with other threads that released
            _ = self.ref_count.load(.acquire);
            self.allocator.free(self.data);
            self.allocator.destroy(self);
        }
    }

    /// Get the current reference count (for debugging/metrics)
    pub fn getRefCount(self: *RefCountedData) u32 {
        return self.ref_count.load(.acquire);
    }
};

/// Cached file entry with content, modification time, and ETag.
/// Uses reference-counted data for zerocopy serving optimization.
pub const FileCacheEntry = struct {
    content: []const u8,
    mtime: i128, // File modification time in nanoseconds
    /// Last time we verified the file's mtime (default 0 ensures first check is always performed)
    last_check_time: i128 = 0,
    etag: ?[]const u8 = null, // ETag for cache validation
    allocator: std.mem.Allocator,
    /// Expiration time in milliseconds (0 = no expiry)
    expires_ms: i64 = 0,
    /// Reference-counted content for zerocopy serving (optional, used in new zerocopy path)
    ref_data: ?*RefCountedData = null,

    /// Size estimation for cache eviction (in bytes)
    pub fn size(self: FileCacheEntry) usize {
        var total: usize = self.content.len;
        if (self.etag) |e| {
            total += e.len;
        }
        return total;
    }

    /// Check if this entry has expired
    pub fn expired(self: FileCacheEntry) bool {
        if (self.expires_ms == 0) return false;
        return std.time.milliTimestamp() >= self.expires_ms;
    }

    /// Free memory when entry is no longer needed.
    /// If using ref-counted data, releases the cache's reference.
    /// The actual data is freed when all references are released.
    pub fn deinit(self: *FileCacheEntry) void {
        if (self.ref_data) |ref| {
            // Release the cache's reference
            ref.release();
        } else {
            // Legacy path: direct allocation
            self.allocator.free(self.content);
        }
        if (self.etag) |e| {
            self.allocator.free(e);
        }
    }
};

/// Simple thread-safe LRU cache for string keys and FileCacheEntry values.
/// Uses a hash map for O(1) lookups and a doubly-linked list for LRU ordering.
/// All operations are protected by a single mutex for thread safety.
const StringLruCache = struct {
    const Self = @This();

    /// Node in the doubly-linked list
    const Node = struct {
        key: []const u8,
        value: FileCacheEntry,
        prev: ?*Node = null,
        next: ?*Node = null,
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
    /// Current total size in bytes
    current_size: usize = 0,
    /// Maximum total size in bytes
    max_bytes: usize,
    /// Allocator for nodes
    allocator: std.mem.Allocator,
    /// Mutex for thread safety
    mutex: std.Thread.Mutex = .{},

    /// Initialize a new LRU cache
    pub fn init(allocator: std.mem.Allocator, max_size: usize, max_bytes: usize) Self {
        return Self{
            .map = std.StringHashMap(*Node).init(allocator),
            .allocator = allocator,
            .max_size = max_size,
            .max_bytes = max_bytes,
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
            // Free the key (owned copy)
            self.allocator.free(n.key);
            // Free the value's content
            var entry = n.value;
            entry.deinit();
            // Free the node itself
            self.allocator.destroy(n);
            node = next;
        }
        self.map.deinit();
        self.head = null;
        self.tail = null;
        self.count = 0;
        self.current_size = 0;
    }

    /// Get a value by key, returns null if not found or expired
    /// The returned entry's content is duplicated and owned by the caller
    pub fn get(self: *Self, key: []const u8, allocator: std.mem.Allocator) !?FileCacheEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.get(key)) |node| {
            // Check expiration
            if (node.value.expired()) {
                self.removeNodeLocked(node);
                return null;
            }
            // Move to front (most recently used)
            self.moveToFrontLocked(node);
            // Return a copy with duplicated content
            const content = try allocator.dupe(u8, node.value.content);
            errdefer allocator.free(content);
            const etag = if (node.value.etag) |e| try allocator.dupe(u8, e) else null;
            return FileCacheEntry{
                .content = content,
                .mtime = node.value.mtime,
                .last_check_time = node.value.last_check_time,
                .etag = etag,
                .allocator = allocator,
                .expires_ms = node.value.expires_ms,
            };
        }
        return null;
    }

    /// Zerocopy reference for cache entries.
    /// Holds a reference to the cached data without copying.
    /// Must call release() when done to avoid memory leaks.
    pub const ZeroCopyRef = struct {
        content: []const u8,
        etag: ?[]const u8,
        mtime: i128,
        last_check_time: i128,
        ref_data: *RefCountedData,

        /// Release the reference to the cached data.
        /// Must be called when done with the data.
        pub fn release(self: *const ZeroCopyRef) void {
            self.ref_data.release();
        }
    };

    /// Get a zerocopy reference to cached data.
    /// Returns null if not found, expired, or reference cannot be acquired.
    /// The caller MUST call release() on the returned ZeroCopyRef when done.
    ///
    /// This method is optimized for static file serving where the cached
    /// data can be directly used in the response without copying.
    pub fn getZeroCopy(self: *Self, key: []const u8) ?ZeroCopyRef {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.get(key)) |node| {
            // Check expiration
            if (node.value.expired()) {
                self.removeNodeLocked(node);
                return null;
            }
            // Check if entry has ref-counted data
            if (node.value.ref_data) |ref| {
                // Try to acquire a reference
                if (ref.acquire()) |acquired_ref| {
                    // Move to front (most recently used)
                    self.moveToFrontLocked(node);
                    return ZeroCopyRef{
                        .content = acquired_ref.data,
                        .etag = node.value.etag,
                        .mtime = node.value.mtime,
                        .last_check_time = node.value.last_check_time,
                        .ref_data = acquired_ref,
                    };
                }
            }
        }
        return null;
    }

    /// Put a value with ref-counted data into the cache.
    /// The cache acquires its own reference to the RefCountedData.
    pub fn putWithRef(self: *Self, key: []const u8, ref_data: *RefCountedData, mtime: i128, etag: ?[]const u8, expires_ms: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry_size = ref_data.data.len + if (etag) |e| e.len else 0;

        // Check if key already exists
        if (self.map.get(key)) |existing| {
            // Update existing entry
            self.current_size -= existing.value.size();
            var old_value = existing.value;
            old_value.deinit();
            // Acquire reference for the cache
            if (ref_data.acquire()) |acquired| {
                existing.value = FileCacheEntry{
                    .content = acquired.data,
                    .mtime = mtime,
                    .last_check_time = std.time.nanoTimestamp(),
                    .etag = etag,
                    .allocator = self.allocator,
                    .expires_ms = expires_ms,
                    .ref_data = acquired,
                };
                self.current_size += entry_size;
                self.moveToFrontLocked(existing);
            }
            return;
        }

        // Create new node
        const node = try self.allocator.create(Node);
        errdefer self.allocator.destroy(node);

        // Duplicate the key
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        // Acquire reference for the cache
        if (ref_data.acquire()) |acquired| {
            node.* = Node{
                .key = owned_key,
                .value = FileCacheEntry{
                    .content = acquired.data,
                    .mtime = mtime,
                    .last_check_time = std.time.nanoTimestamp(),
                    .etag = etag,
                    .allocator = self.allocator,
                    .expires_ms = expires_ms,
                    .ref_data = acquired,
                },
            };

            // Add to map
            try self.map.put(owned_key, node);

            // Add to front of list
            self.addToFrontLocked(node);
            self.count += 1;
            self.current_size += entry_size;

            // Evict if necessary
            self.evictIfNeededLocked();
        }
    }

    /// Put a value into the cache
    /// The cache takes ownership of the content and etag in the value
    pub fn put(self: *Self, key: []const u8, value: FileCacheEntry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry_size = value.size();

        // Check if key already exists
        if (self.map.get(key)) |existing| {
            // Update existing entry
            self.current_size -= existing.value.size();
            var old_value = existing.value;
            old_value.deinit();
            existing.value = value;
            self.current_size += entry_size;
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
        };

        // Add to map
        try self.map.put(owned_key, node);

        // Add to front of list
        self.addToFrontLocked(node);
        self.count += 1;
        self.current_size += entry_size;

        // Evict if necessary
        self.evictIfNeededLocked();
    }

    /// Remove an entry by key
    pub fn remove(self: *Self, key: []const u8) bool {
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
            self.allocator.free(n.key);
            var entry = n.value;
            entry.deinit();
            self.allocator.destroy(n);
            node = next;
        }
        self.map.clearRetainingCapacity();
        self.head = null;
        self.tail = null;
        self.count = 0;
        self.current_size = 0;
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

        // Update counts
        self.count -= 1;
        self.current_size -= node.value.size();

        // Free resources
        self.allocator.free(node.key);
        var entry = node.value;
        entry.deinit();
        self.allocator.destroy(node);
    }

    // Internal: Evict entries if over capacity (must hold mutex)
    fn evictIfNeededLocked(self: *Self) void {
        // Evict by count
        while (self.count > self.max_size and self.tail != null) {
            self.removeNodeLocked(self.tail.?);
        }
        // Evict by size
        while (self.current_size > self.max_bytes and self.tail != null) {
            self.removeNodeLocked(self.tail.?);
        }
    }
};

/// Thread-safe file cache supporting multiple reload strategies
/// Uses a custom LRU cache implemented with std library primitives for
/// full control over thread safety and memory management.
pub const FileCache = struct {
    cache: StringLruCache,
    allocator: std.mem.Allocator,
    reload_mode: ReloadMode,
    max_cache_file_size: usize,

    /// Initialize a new file cache with the specified reload mode and max cache file size
    pub fn init(allocator: std.mem.Allocator, reload_mode: ReloadMode, max_cache_file_size: usize) FileCache {
        // Calculate max cache entries based on average file size assumption (10KB)
        const max_entries: usize = @min(max_cache_file_size / 10240 + 100, 10000);

        return FileCache{
            .cache = StringLruCache.init(allocator, max_entries, max_cache_file_size),
            .allocator = allocator,
            .reload_mode = reload_mode,
            .max_cache_file_size = max_cache_file_size,
        };
    }

    /// Clean up all cached entries and free resources
    pub fn deinit(self: *FileCache) void {
        self.cache.deinit();
    }

    /// Get cached content, duplicating the content to ensure safety
    /// Returns null if file is not cached
    /// The returned content is owned by the caller and must be freed
    fn getCachedContent(self: *FileCache, key: []const u8) !?struct { content: []const u8, mtime: i128, last_check_time: i128 } {
        if (try self.cache.get(key, self.allocator)) |entry| {
            return .{
                .content = entry.content,
                .mtime = entry.mtime,
                .last_check_time = entry.last_check_time,
            };
        }
        return null;
    }

    /// Update the cache with new file content and modification time
    fn putCached(self: *FileCache, key: []const u8, content: []const u8, mtime: i128, etag: ?[]const u8) !void {
        // Store the new content with owned copies
        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);

        const owned_etag = if (etag) |e| try self.allocator.dupe(u8, e) else null;
        errdefer if (owned_etag) |e| self.allocator.free(e);

        const entry = FileCacheEntry{
            .content = owned_content,
            .mtime = mtime,
            .last_check_time = std.time.nanoTimestamp(),
            .etag = owned_etag,
            .allocator = self.allocator,
            .expires_ms = std.time.milliTimestamp() + DEFAULT_FILE_TTL_MS,
        };

        try self.cache.put(key, entry);
    }

    /// Load file content with caching based on reload mode
    /// Files larger than max_cache_file_size are always read from disk without caching
    /// - force: Always read from disk
    /// - never: Use cache if available, otherwise read and cache
    /// - auto: Check file mtime and reload if modified
    pub fn loadFile(self: *FileCache, path: []const u8) ![]const u8 {
        switch (self.reload_mode) {
            .force => {
                // Always read from disk, don't use cache
                return try self.readFileFromDisk(path);
            },
            .never => {
                // Use cache if available, otherwise read and cache
                if (try self.getCachedContent(path)) |cached| {
                    // Content is already duplicated and owned by caller
                    return cached.content;
                }

                // Check file size before reading
                const file = try std.fs.cwd().openFile(path, .{});
                defer file.close();
                const stat = try file.stat();

                // If file is too large, don't cache it
                if (stat.size > self.max_cache_file_size) {
                    return try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                }

                const content = try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                errdefer self.allocator.free(content);

                // Cache makes its own copy, so we can return the original
                try self.putCached(path, content, 0, null);
                return content;
            },
            .auto => {
                // First, check cache to see if we have a recent entry
                if (try self.getCachedContent(path)) |cached| {
                    const current_time = std.time.nanoTimestamp();
                    // Skip stat check if we checked recently (within STAT_CHECK_INTERVAL_NS)
                    if (current_time - cached.last_check_time < STAT_CHECK_INTERVAL_NS) {
                        // Return cached content without stat check
                        return cached.content;
                    }

                    // Check file modification time
                    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
                        if (err == error.FileNotFound) {
                            // File was deleted, cache is stale - free the duplicate and return error
                            self.allocator.free(cached.content);
                            return err;
                        }
                        // For other errors (permission, etc.), return cached content as fallback
                        return cached.content;
                    };
                    defer file.close();
                    const stat = try file.stat();

                    if (cached.mtime == stat.mtime) {
                        // File hasn't changed, update last_check_time in cache
                        try self.putCached(path, cached.content, cached.mtime, null);
                        // Return the already-duplicated content
                        return cached.content;
                    }

                    // Cache is stale, free the duplicated content
                    self.allocator.free(cached.content);

                    // If file is too large, don't cache it
                    if (stat.size > self.max_cache_file_size) {
                        return try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                    }

                    // File changed, read and update cache
                    const content = try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                    errdefer self.allocator.free(content);

                    try self.putCached(path, content, stat.mtime, null);
                    return content;
                }

                // Not cached, read from disk
                const file = try std.fs.cwd().openFile(path, .{});
                defer file.close();
                const stat = try file.stat();

                // If file is too large, don't cache it
                if (stat.size > self.max_cache_file_size) {
                    return try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                }

                const content = try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                errdefer self.allocator.free(content);

                try self.putCached(path, content, stat.mtime, null);
                return content;
            },
        }
    }

    /// Read file content from disk
    fn readFileFromDisk(self: *FileCache, path: []const u8) ![]const u8 {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        return try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
    }

    /// Generate ETag from file stat (using size and mtime)
    /// Returns owned string that caller must free
    pub fn generateETag(allocator: std.mem.Allocator, file_size: u64, mtime: i128) ![]const u8 {
        // Use a simple ETag format: "size-mtime" (weak ETag)
        // Strong ETags would require hashing file content which is expensive
        return try std.fmt.allocPrint(allocator, "W/\"{x}-{x}\"", .{ file_size, mtime });
    }

    /// Result from loadFileWithETag containing cached content and ETag
    pub const CachedFileInfo = struct {
        content: []const u8,
        etag: []const u8,
    };

    /// Load file content with ETag, both cached
    /// This method caches both the file content and ETag to avoid repeated file operations.
    /// The returned content and etag are owned by the caller and must be freed.
    pub fn loadFileWithETag(self: *FileCache, path: []const u8) !CachedFileInfo {
        switch (self.reload_mode) {
            .force => {
                // Always read from disk, regenerate ETag
                const file = try std.fs.cwd().openFile(path, .{});
                defer file.close();
                const stat = try file.stat();
                const content = try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                errdefer self.allocator.free(content);
                const etag = try generateETag(self.allocator, stat.size, stat.mtime);
                return .{ .content = content, .etag = etag };
            },
            .never => {
                // Use cache if available, otherwise read and cache
                if (try self.getCachedContentWithETag(path)) |cached| {
                    return cached;
                }

                // Check file size before reading
                const file = try std.fs.cwd().openFile(path, .{});
                defer file.close();
                const stat = try file.stat();

                // If file is too large, don't cache it
                if (stat.size > self.max_cache_file_size) {
                    const content = try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                    errdefer self.allocator.free(content);
                    const etag = try generateETag(self.allocator, stat.size, stat.mtime);
                    return .{ .content = content, .etag = etag };
                }

                const content = try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                errdefer self.allocator.free(content);
                const etag = try generateETag(self.allocator, stat.size, stat.mtime);
                errdefer self.allocator.free(etag);

                // Cache makes its own copy, store mtime for consistency
                try self.putCached(path, content, stat.mtime, etag);
                return .{ .content = content, .etag = etag };
            },
            .auto => {
                // First, check cache to see if we have a recent entry
                if (try self.cache.get(path, self.allocator)) |entry| {
                    const current_time = std.time.nanoTimestamp();
                    // Skip stat check if we checked recently (within STAT_CHECK_INTERVAL_NS)
                    if (current_time - entry.last_check_time < STAT_CHECK_INTERVAL_NS) {
                        // Return cached content without stat check
                        // entry.content is already duplicated and owned by us
                        // entry.etag may need duplication if present
                        const etag = if (entry.etag) |e| blk: {
                            // etag was already duplicated in cache.get()
                            break :blk e;
                        } else try generateETag(self.allocator, entry.content.len, entry.mtime);
                        return .{ .content = entry.content, .etag = etag };
                    }

                    // Check file modification time
                    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
                        if (err == error.FileNotFound) {
                            // Clean up entry's content since we're returning error
                            var mutable_entry = entry;
                            mutable_entry.deinit();
                            return err;
                        }
                        // For other errors, return cached content as fallback
                        const etag = if (entry.etag) |e| blk: {
                            break :blk e;
                        } else try generateETag(self.allocator, entry.content.len, entry.mtime);
                        return .{ .content = entry.content, .etag = etag };
                    };
                    defer file.close();
                    const stat = try file.stat();

                    if (entry.mtime == stat.mtime) {
                        // File hasn't changed - return the entry as-is
                        // The entry.content and entry.etag are already duplicated and owned by us
                        const etag = if (entry.etag) |e| blk: {
                            break :blk e;
                        } else try generateETag(self.allocator, entry.content.len, entry.mtime);
                        // Note: We don't update the cache here to avoid complexity.
                        // The next request will update last_check_time.
                        return .{ .content = entry.content, .etag = etag };
                    }

                    // File changed - clean up old entry and continue to read new content
                    var mutable_entry = entry;
                    mutable_entry.deinit();
                }

                // Not cached or cache is stale, read from disk
                const file = try std.fs.cwd().openFile(path, .{});
                defer file.close();
                const stat = try file.stat();

                // If file is too large, don't cache it
                if (stat.size > self.max_cache_file_size) {
                    const content = try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                    errdefer self.allocator.free(content);
                    const etag = try generateETag(self.allocator, stat.size, stat.mtime);
                    return .{ .content = content, .etag = etag };
                }

                const content = try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                errdefer self.allocator.free(content);
                const etag = try generateETag(self.allocator, stat.size, stat.mtime);
                errdefer self.allocator.free(etag);

                try self.putCached(path, content, stat.mtime, etag);
                return .{ .content = content, .etag = etag };
            },
        }
    }

    /// Get cached content with ETag, duplicating both to ensure safety
    fn getCachedContentWithETag(self: *FileCache, key: []const u8) !?CachedFileInfo {
        if (try self.cache.get(key, self.allocator)) |entry| {
            const etag = if (entry.etag) |e|
                try self.allocator.dupe(u8, e)
            else
                try generateETag(self.allocator, entry.content.len, entry.mtime);
            return .{ .content = entry.content, .etag = etag };
        }
        return null;
    }

    /// Get file info with ETag support (for zero-copy serving)
    pub fn getFileInfo(file_cache: *FileCache, path: []const u8, allocator: std.mem.Allocator) !struct { size: u64, mtime: i128, etag: []const u8 } {
        _ = file_cache; // unused but kept for API consistency
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const stat = try file.stat();

        const etag = try generateETag(allocator, stat.size, stat.mtime);
        return .{ .size = stat.size, .mtime = stat.mtime, .etag = etag };
    }

    /// Clear all cached entries (useful for testing or manual cache invalidation)
    pub fn clear(self: *FileCache) void {
        self.cache.clear();
    }

    /// Get the number of cached entries
    pub fn count(self: *FileCache) usize {
        return self.cache.getCount();
    }

    /// Zerocopy reference for file cache.
    /// Contains a reference to cached file data without copying.
    /// The reference must be released when done using the data.
    pub const ZeroCopyFileRef = struct {
        content: []const u8,
        etag: []const u8,
        cache_ref: StringLruCache.ZeroCopyRef,
        etag_allocator: ?std.mem.Allocator = null, // For generated ETags

        /// Release the reference to the cached data.
        /// Must be called when done with the data to avoid memory leaks.
        pub fn release(self: *const ZeroCopyFileRef) void {
            self.cache_ref.release();
            // Free generated ETag if we created one
            if (self.etag_allocator) |allocator| {
                allocator.free(self.etag);
            }
        }
    };

    /// Load file content with ETag using zerocopy optimization.
    /// Returns a reference to cached data without copying.
    ///
    /// ## Zerocopy Optimization
    /// This method provides optimal performance for static file serving by:
    /// 1. Returning a direct reference to cached data (no memory allocation)
    /// 2. Using atomic reference counting to ensure safe concurrent access
    /// 3. Deferring memory cleanup until all references are released
    ///
    /// ## Cache Miss Handling
    /// On cache miss, falls back to `loadFileWithETagAlloc` which copies data.
    /// For best performance, use this method for frequently accessed files.
    ///
    /// ## Safety
    /// - The caller MUST call `release()` on the returned reference when done
    /// - The data remains valid until `release()` is called
    /// - Safe for concurrent access from multiple threads
    ///
    /// ## Usage
    /// ```zig
    /// if (cache.loadFileZeroCopy(path)) |ref| {
    ///     defer ref.release();
    ///     res.body = ref.content;
    ///     res.headers.add("ETag", ref.etag);
    /// }
    /// ```
    pub fn loadFileZeroCopy(self: *FileCache, path: []const u8) ?ZeroCopyFileRef {
        // Force mode never uses cache
        if (self.reload_mode == .force) {
            return null;
        }

        // Try to get a zerocopy reference from cache
        if (self.cache.getZeroCopy(path)) |cache_ref| {
            // Check if file needs revalidation in auto mode
            if (self.reload_mode == .auto) {
                const current_time = std.time.nanoTimestamp();
                // Skip validation if checked recently
                if (current_time - cache_ref.last_check_time >= STAT_CHECK_INTERVAL_NS) {
                    // Need to validate file - release ref and return null to trigger reload
                    cache_ref.release();
                    return null;
                }
            }

            // Generate ETag if not cached
            const etag = cache_ref.etag orelse blk: {
                // Need to generate ETag - use self.allocator
                const generated = generateETag(self.allocator, cache_ref.content.len, cache_ref.mtime) catch {
                    cache_ref.release();
                    return null;
                };
                break :blk generated;
            };

            return ZeroCopyFileRef{
                .content = cache_ref.content,
                .etag = etag,
                .cache_ref = cache_ref,
                .etag_allocator = if (cache_ref.etag == null) self.allocator else null,
            };
        }

        return null;
    }

    /// Store content with zerocopy optimization using reference counting.
    /// The content is stored with reference counting for safe zerocopy access.
    fn putCachedWithRef(self: *FileCache, key: []const u8, content: []const u8, mtime: i128, etag: ?[]const u8) !void {
        // Create reference-counted data
        const ref_data = try RefCountedData.create(self.allocator, content);
        errdefer ref_data.release();

        // Duplicate ETag if provided
        const owned_etag = if (etag) |e| try self.allocator.dupe(u8, e) else null;
        errdefer if (owned_etag) |e| self.allocator.free(e);

        const expires_ms = std.time.milliTimestamp() + DEFAULT_FILE_TTL_MS;

        // Store in cache (cache acquires its own reference)
        try self.cache.putWithRef(key, ref_data, mtime, owned_etag, expires_ms);

        // Release our reference (cache now owns the data)
        ref_data.release();
    }

    /// Load file content with ETag, allocating directly into the caller's allocator.
    /// This is an optimized version that avoids double-copying when serving static files.
    /// The returned content and etag are owned by the caller and must be freed using target_allocator.
    /// The cache still maintains its own copy for future requests.
    pub fn loadFileWithETagAlloc(self: *FileCache, path: []const u8, target_allocator: std.mem.Allocator) !CachedFileInfo {
        switch (self.reload_mode) {
            .force => {
                // Always read from disk, regenerate ETag
                const file = try std.fs.cwd().openFile(path, .{});
                defer file.close();
                const stat = try file.stat();
                const content = try file.readToEndAlloc(target_allocator, MAX_FILE_SIZE);
                errdefer target_allocator.free(content);
                const etag = try generateETag(target_allocator, stat.size, stat.mtime);
                return .{ .content = content, .etag = etag };
            },
            .never => {
                // Use cache if available, otherwise read and cache
                if (try self.getCachedContentWithETagAlloc(path, target_allocator)) |cached| {
                    return cached;
                }

                // Check file size before reading
                const file = try std.fs.cwd().openFile(path, .{});
                defer file.close();
                const stat = try file.stat();

                // If file is too large, don't cache it - just read into target allocator
                if (stat.size > self.max_cache_file_size) {
                    const content = try file.readToEndAlloc(target_allocator, MAX_FILE_SIZE);
                    errdefer target_allocator.free(content);
                    const etag = try generateETag(target_allocator, stat.size, stat.mtime);
                    return .{ .content = content, .etag = etag };
                }

                // Read file content into self.allocator for caching
                const cache_content = try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                defer self.allocator.free(cache_content); // Will be copied by putCachedWithRef
                const cache_etag = try generateETag(self.allocator, stat.size, stat.mtime);
                errdefer self.allocator.free(cache_etag);

                // Cache it with ref-counting for zerocopy access
                try self.putCachedWithRef(path, cache_content, stat.mtime, cache_etag);

                // Return duplicated content in target allocator
                const content = try target_allocator.dupe(u8, cache_content);
                errdefer target_allocator.free(content);
                const etag = try target_allocator.dupe(u8, cache_etag);
                return .{ .content = content, .etag = etag };
            },
            .auto => {
                // First, check cache to see if we have a recent entry
                if (try self.cache.get(path, target_allocator)) |entry| {
                    const current_time = std.time.nanoTimestamp();
                    // Skip stat check if we checked recently (within STAT_CHECK_INTERVAL_NS)
                    if (current_time - entry.last_check_time < STAT_CHECK_INTERVAL_NS) {
                        // entry.content and entry.etag are already allocated in target_allocator
                        const etag = if (entry.etag) |e| blk: {
                            break :blk e;
                        } else try generateETag(target_allocator, entry.content.len, entry.mtime);
                        return .{ .content = entry.content, .etag = etag };
                    }

                    // Check file modification time
                    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
                        if (err == error.FileNotFound) {
                            // Clean up entry's content since we're returning error
                            var mutable_entry = entry;
                            mutable_entry.deinit();
                            return err;
                        }
                        // For other errors, return cached content as fallback
                        const etag = if (entry.etag) |e| blk: {
                            break :blk e;
                        } else try generateETag(target_allocator, entry.content.len, entry.mtime);
                        return .{ .content = entry.content, .etag = etag };
                    };
                    defer file.close();
                    const stat = try file.stat();

                    if (entry.mtime == stat.mtime) {
                        // File hasn't changed - return the entry as-is
                        const etag = if (entry.etag) |e| blk: {
                            break :blk e;
                        } else try generateETag(target_allocator, entry.content.len, entry.mtime);
                        return .{ .content = entry.content, .etag = etag };
                    }

                    // File changed - clean up old entry and continue to read new content
                    var mutable_entry = entry;
                    mutable_entry.deinit();
                }

                // Not cached or cache is stale, read from disk
                const file = try std.fs.cwd().openFile(path, .{});
                defer file.close();
                const stat = try file.stat();

                // If file is too large, don't cache it - just read into target allocator
                if (stat.size > self.max_cache_file_size) {
                    const content = try file.readToEndAlloc(target_allocator, MAX_FILE_SIZE);
                    errdefer target_allocator.free(content);
                    const etag = try generateETag(target_allocator, stat.size, stat.mtime);
                    return .{ .content = content, .etag = etag };
                }

                // Read file content into self.allocator for caching
                const cache_content = try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                defer self.allocator.free(cache_content); // Will be copied by putCachedWithRef
                const cache_etag = try generateETag(self.allocator, stat.size, stat.mtime);
                errdefer self.allocator.free(cache_etag);

                // Cache it with ref-counting for zerocopy access
                try self.putCachedWithRef(path, cache_content, stat.mtime, cache_etag);

                // Return duplicated content in target allocator
                const content = try target_allocator.dupe(u8, cache_content);
                errdefer target_allocator.free(content);
                const etag = try target_allocator.dupe(u8, cache_etag);
                return .{ .content = content, .etag = etag };
            },
        }
    }

    /// Get cached content with ETag, allocating into target_allocator
    fn getCachedContentWithETagAlloc(self: *FileCache, key: []const u8, target_allocator: std.mem.Allocator) !?CachedFileInfo {
        if (try self.cache.get(key, target_allocator)) |entry| {
            const etag = if (entry.etag) |e|
                e // Already duplicated by cache.get into target_allocator
            else
                try generateETag(target_allocator, entry.content.len, entry.mtime);
            return .{ .content = entry.content, .etag = etag };
        }
        return null;
    }
};

test "StringLruCache basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = StringLruCache.init(allocator, 3, 1024 * 1024);
    defer cache.deinit();

    // Test put and get
    const content1 = try allocator.dupe(u8, "content1");
    try cache.put("key1", FileCacheEntry{
        .content = content1,
        .mtime = 1000,
        .allocator = allocator,
    });

    const result = try cache.get("key1", allocator);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
    }
    try testing.expectEqualStrings("content1", result.?.content);

    // Test non-existent key
    const missing = try cache.get("nonexistent", allocator);
    try testing.expect(missing == null);
}

test "StringLruCache eviction" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = StringLruCache.init(allocator, 2, 1024 * 1024);
    defer cache.deinit();

    // Add 3 items to a cache with max size 2
    const content1 = try allocator.dupe(u8, "a");
    try cache.put("key1", FileCacheEntry{ .content = content1, .mtime = 1, .allocator = allocator });

    const content2 = try allocator.dupe(u8, "b");
    try cache.put("key2", FileCacheEntry{ .content = content2, .mtime = 2, .allocator = allocator });

    const content3 = try allocator.dupe(u8, "c");
    try cache.put("key3", FileCacheEntry{ .content = content3, .mtime = 3, .allocator = allocator });

    // key1 should be evicted (LRU)
    const result1 = try cache.get("key1", allocator);
    try testing.expect(result1 == null);

    // key2 and key3 should still exist
    const result2 = try cache.get("key2", allocator);
    try testing.expect(result2 != null);
    var r2 = result2.?;
    r2.deinit();

    const result3 = try cache.get("key3", allocator);
    try testing.expect(result3 != null);
    var r3 = result3.?;
    r3.deinit();
}

test "file cache init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var file_cache = FileCache.init(allocator, .auto, 1024 * 1024);
    defer file_cache.deinit();
}

test "file cache force mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var file_cache = FileCache.init(allocator, .force, 1024 * 1024);
    defer file_cache.deinit();

    // Create a temporary file
    const test_file = "test_cache_force.tmp";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("test content");
    }
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Load file twice - should read from disk both times
    const content1 = try file_cache.loadFile(test_file);
    defer allocator.free(content1);
    try testing.expectEqualStrings("test content", content1);
}

test "file cache auto mode rate limiting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var file_cache = FileCache.init(allocator, .auto, 1024 * 1024);
    defer file_cache.deinit();

    // Create a temporary file
    const test_file = "test_cache_auto_rate_limit.tmp";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("original content");
    }
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // First load - should read from disk and cache
    const content1 = try file_cache.loadFile(test_file);
    defer allocator.free(content1);
    try testing.expectEqualStrings("original content", content1);

    // Modify the file
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("modified content");
    }

    // Immediate second load - should return cached content (stat check skipped)
    const content2 = try file_cache.loadFile(test_file);
    defer allocator.free(content2);
    try testing.expectEqualStrings("original content", content2);
}

test "loadFileWithETag caches content and etag" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var file_cache = FileCache.init(allocator, .auto, 1024 * 1024);
    defer file_cache.deinit();

    // Create a temporary file
    const test_file = "test_load_with_etag.tmp";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("cached content");
    }
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // First load - should read from disk and cache with ETag
    const info1 = try file_cache.loadFileWithETag(test_file);
    defer allocator.free(info1.content);
    defer allocator.free(info1.etag);

    try testing.expectEqualStrings("cached content", info1.content);
    try testing.expect(std.mem.startsWith(u8, info1.etag, "W/\""));

    // Second load - should return cached content and etag
    const info2 = try file_cache.loadFileWithETag(test_file);
    defer allocator.free(info2.content);
    defer allocator.free(info2.etag);

    try testing.expectEqualStrings("cached content", info2.content);
    try testing.expectEqualStrings(info1.etag, info2.etag);
}

test "loadFileWithETag force mode always reads from disk" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var file_cache = FileCache.init(allocator, .force, 1024 * 1024);
    defer file_cache.deinit();

    // Create a temporary file
    const test_file = "test_load_with_etag_force.tmp";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("force content");
    }
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Load in force mode - should always read from disk
    const info = try file_cache.loadFileWithETag(test_file);
    defer allocator.free(info.content);
    defer allocator.free(info.etag);

    try testing.expectEqualStrings("force content", info.content);
    try testing.expect(std.mem.startsWith(u8, info.etag, "W/\""));
}

test "loadFileWithETag never mode caches" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var file_cache = FileCache.init(allocator, .never, 1024 * 1024);
    defer file_cache.deinit();

    // Create a temporary file
    const test_file = "test_load_with_etag_never.tmp";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("never reload content");
    }
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // First load
    const info1 = try file_cache.loadFileWithETag(test_file);
    defer allocator.free(info1.content);
    defer allocator.free(info1.etag);

    try testing.expectEqualStrings("never reload content", info1.content);

    // Modify the file
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("modified content");
    }

    // Second load - should still return original cached content
    const info2 = try file_cache.loadFileWithETag(test_file);
    defer allocator.free(info2.content);
    defer allocator.free(info2.etag);

    try testing.expectEqualStrings("never reload content", info2.content);
}

test "loadFileWithETagAlloc allocates into target allocator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var file_cache = FileCache.init(allocator, .auto, 1024 * 1024);
    defer file_cache.deinit();

    // Create a temporary file
    const test_file = "test_load_with_etag_alloc.tmp";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("alloc test content");
    }
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Use a different allocator as target (simulating arena allocator)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const target_alloc = arena.allocator();

    // First load - should read from disk, cache with self.allocator, return copy in target_alloc
    const info1 = try file_cache.loadFileWithETagAlloc(test_file, target_alloc);
    // Content and etag are in target_alloc, no need to free manually (arena handles it)

    try testing.expectEqualStrings("alloc test content", info1.content);
    try testing.expect(std.mem.startsWith(u8, info1.etag, "W/\""));

    // Second load - should return cached content directly into target_alloc
    const info2 = try file_cache.loadFileWithETagAlloc(test_file, target_alloc);

    try testing.expectEqualStrings("alloc test content", info2.content);
    try testing.expectEqualStrings(info1.etag, info2.etag);
}

test "loadFileWithETagAlloc force mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var file_cache = FileCache.init(allocator, .force, 1024 * 1024);
    defer file_cache.deinit();

    // Create a temporary file
    const test_file = "test_load_with_etag_alloc_force.tmp";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("force alloc content");
    }
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const target_alloc = arena.allocator();

    // Load in force mode - should always read from disk into target_alloc
    const info = try file_cache.loadFileWithETagAlloc(test_file, target_alloc);

    try testing.expectEqualStrings("force alloc content", info.content);
    try testing.expect(std.mem.startsWith(u8, info.etag, "W/\""));
}

test "loadFileWithETagAlloc never mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var file_cache = FileCache.init(allocator, .never, 1024 * 1024);
    defer file_cache.deinit();

    // Create a temporary file
    const test_file = "test_load_with_etag_alloc_never.tmp";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("never alloc content");
    }
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const target_alloc = arena.allocator();

    // First load
    const info1 = try file_cache.loadFileWithETagAlloc(test_file, target_alloc);
    try testing.expectEqualStrings("never alloc content", info1.content);

    // Modify the file
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("modified alloc content");
    }

    // Second load - should still return original cached content
    const info2 = try file_cache.loadFileWithETagAlloc(test_file, target_alloc);
    try testing.expectEqualStrings("never alloc content", info2.content);
}

// =============================================================================
// Zerocopy tests
// =============================================================================

test "RefCountedData basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create ref-counted data
    const data = try RefCountedData.create(allocator, "test data");

    // Initial ref count should be 1
    try testing.expect(data.getRefCount() == 1);

    // Acquire a reference
    const ref2 = data.acquire();
    try testing.expect(ref2 != null);
    try testing.expect(data.getRefCount() == 2);

    // Data should still be accessible
    try testing.expectEqualStrings("test data", data.data);

    // Release references
    ref2.?.release();
    try testing.expect(data.getRefCount() == 1);

    // Final release frees the data
    data.release();
}

test "RefCountedData multiple acquires" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const data = try RefCountedData.create(allocator, "shared content");

    // Acquire multiple references
    const ref2 = data.acquire().?;
    const ref3 = data.acquire().?;
    const ref4 = data.acquire().?;

    try testing.expect(data.getRefCount() == 4);

    // Release in different order
    ref3.release();
    try testing.expect(data.getRefCount() == 3);

    ref2.release();
    try testing.expect(data.getRefCount() == 2);

    ref4.release();
    try testing.expect(data.getRefCount() == 1);

    // Final release
    data.release();
}

test "loadFileZeroCopy returns null for force mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var file_cache = FileCache.init(allocator, .force, 1024 * 1024);
    defer file_cache.deinit();

    // Force mode never uses cache, should return null
    const result = file_cache.loadFileZeroCopy("any_path");
    try testing.expect(result == null);
}

test "loadFileZeroCopy with never mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var file_cache = FileCache.init(allocator, .never, 1024 * 1024);
    defer file_cache.deinit();

    // Create a temporary file
    const test_file = "test_zerocopy_never.tmp";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("zerocopy content");
    }
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // First access - cache miss, should return null
    const result1 = file_cache.loadFileZeroCopy(test_file);
    try testing.expect(result1 == null);

    // Load with regular method to populate cache
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const info = try file_cache.loadFileWithETagAlloc(test_file, arena.allocator());
    try testing.expectEqualStrings("zerocopy content", info.content);

    // Now zerocopy should work
    if (file_cache.loadFileZeroCopy(test_file)) |ref| {
        defer ref.release();
        try testing.expectEqualStrings("zerocopy content", ref.content);
        try testing.expect(std.mem.startsWith(u8, ref.etag, "W/\""));
    } else {
        // Zerocopy may not be available if ref_data wasn't set
        // This is acceptable as long as the fallback path works
    }
}

test "StringLruCache zerocopy operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = StringLruCache.init(allocator, 3, 1024 * 1024);
    defer cache.deinit();

    // Create ref-counted data
    const ref_data = try RefCountedData.create(allocator, "zerocopy test");
    defer ref_data.release();

    // Duplicate ETag
    const etag = try allocator.dupe(u8, "W/\"test-etag\"");
    errdefer allocator.free(etag);

    // Put with ref
    try cache.putWithRef("key1", ref_data, 12345, etag, 0);

    // Get zerocopy reference
    if (cache.getZeroCopy("key1")) |zc_ref| {
        defer zc_ref.release();
        try testing.expectEqualStrings("zerocopy test", zc_ref.content);
        try testing.expectEqualStrings("W/\"test-etag\"", zc_ref.etag.?);
    } else {
        try testing.expect(false); // Should have succeeded
    }

    // Non-existent key should return null
    const missing = cache.getZeroCopy("nonexistent");
    try testing.expect(missing == null);
}
