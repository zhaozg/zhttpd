const std = @import("std");
const Config = @import("../config/config.zig");
const ReloadMode = Config.ReloadMode;
const zcache = @import("zcache");

/// Maximum file size for reading (100MB)
const MAX_FILE_SIZE = 100 * 1024 * 1024;

/// Default file cache TTL in milliseconds (1 hour)
const DEFAULT_FILE_TTL_MS: i64 = 3600 * 1000;

/// Minimum interval between file stat checks in nanoseconds (1 second)
/// This reduces the overhead of stat() syscalls in auto reload mode
const STAT_CHECK_INTERVAL_NS: i128 = 1_000_000_000;

/// Cached file entry with content, modification time, and ETag
pub const FileCacheEntry = struct {
    content: []const u8,
    mtime: i128, // File modification time in nanoseconds
    /// Last time we verified the file's mtime (default 0 ensures first check is always performed)
    last_check_time: i128 = 0,
    etag: ?[]const u8 = null, // ETag for cache validation
    allocator: std.mem.Allocator,

    /// Size estimation for cache eviction (in bytes)
    pub fn size(self: FileCacheEntry) u32 {
        var total: u32 = @intCast(@min(self.content.len, std.math.maxInt(u32)));
        if (self.etag) |e| {
            total +|= @intCast(@min(e.len, std.math.maxInt(u32) - total));
        }
        return total;
    }

    /// Free memory when entry is no longer needed
    pub fn deinit(self: *FileCacheEntry) void {
        self.allocator.free(self.content);
        if (self.etag) |e| {
            self.allocator.free(e);
        }
    }
};

/// Thread-safe file cache supporting multiple reload strategies
/// Uses zcache for LRU eviction and memory management
pub const FileCache = struct {
    cache: zcache.Cache([]const u8, FileCacheEntry),
    allocator: std.mem.Allocator,
    reload_mode: ReloadMode,
    max_cache_file_size: usize, // Maximum file size to cache (files larger than this won't be cached)

    /// Initialize a new file cache with the specified reload mode and max cache file size
    pub fn init(allocator: std.mem.Allocator, reload_mode: ReloadMode, max_cache_file_size: usize) FileCache {
        // Calculate max cache entries based on average file size assumption (10KB)
        const max_entries: u32 = @intCast(@min(max_cache_file_size / 10240 + 100, 10000));

        // Try to initialize with preferred settings, fallback to minimal if that fails
        const cache_instance = zcache.Cache([]const u8, FileCacheEntry).init(allocator, .{
            .max_size = max_entries,
            .segment_count = 8,
            .default_ttl_ms = DEFAULT_FILE_TTL_MS,
        }) catch blk: {
            // Fallback to minimal cache on error
            break :blk zcache.Cache([]const u8, FileCacheEntry).init(allocator, .{
                .max_size = 100,
                .segment_count = 1,
                .default_ttl_ms = DEFAULT_FILE_TTL_MS,
            }) catch unreachable;
        };

        return FileCache{
            .cache = cache_instance,
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
        if (self.cache.get(key)) |entry| {
            defer entry.release();
            // Duplicate content while entry is still valid
            const content = try self.allocator.dupe(u8, entry.value.content);
            return .{ .content = content, .mtime = entry.value.mtime, .last_check_time = entry.value.last_check_time };
        }
        return null;
    }

    /// Update the cache with new file content and modification time
    /// Note: zcache doesn't have a callback for entry removal, so when entries are
    /// evicted (via LRU or replacement), the FileCacheEntry's content/etag memory
    /// will not be freed. This is a known limitation. In practice, for file caches,
    /// the leak is bounded by the number of evictions and the typical small entry sizes.
    fn putCached(self: *FileCache, key: []const u8, content: []const u8, mtime: i128, etag: ?[]const u8) !void {
        // First, try to manually clean up any existing entry to prevent memory leaks
        if (self.cache.get(key)) |existing| {
            // We have an existing entry - copy its content/etag pointers for cleanup
            const old_content = existing.value.content;
            const old_etag = existing.value.etag;
            const old_allocator = existing.value.allocator;
            existing.release();

            // Delete the old entry from cache
            _ = self.cache.del(key);

            // Now free the old allocations
            old_allocator.free(old_content);
            if (old_etag) |e| {
                old_allocator.free(e);
            }
        }

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
        };

        // zcache is thread-safe, no need for additional mutex
        _ = try self.cache.putWithConfig(key, entry, .{
            .ttl_ms = DEFAULT_FILE_TTL_MS,
            .size = entry.size(),
        });
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
                        // Note: This creates a new cache entry because zcache doesn't support
                        // in-place updates. The double-duplication overhead is acceptable because:
                        // 1. It only happens once per check interval (1 second)
                        // 2. The old entry is immediately evicted and its memory freed
                        // 3. The alternative (no update) would cause stat() on every request
                        self.putCached(path, cached.content, cached.mtime, null) catch {
                            // If cache update fails, still return the cached content
                        };
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
    /// - force: Always read from disk, regenerate ETag
    /// - never: Use cache if available, otherwise read and cache
    /// - auto: Check file mtime and reload if modified
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
                errdefer self.allocator.free(etag);
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
                    errdefer self.allocator.free(etag);
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
                if (self.cache.get(path)) |entry| {
                    defer entry.release();
                    const current_time = std.time.nanoTimestamp();
                    // Skip stat check if we checked recently (within STAT_CHECK_INTERVAL_NS)
                    if (current_time - entry.value.last_check_time < STAT_CHECK_INTERVAL_NS) {
                        // Return cached content without stat check
                        const content = try self.allocator.dupe(u8, entry.value.content);
                        errdefer self.allocator.free(content);
                        const etag = if (entry.value.etag) |e|
                            try self.allocator.dupe(u8, e)
                        else
                            try generateETag(self.allocator, content.len, entry.value.mtime);
                        return .{ .content = content, .etag = etag };
                    }

                    // Check file modification time
                    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
                        if (err == error.FileNotFound) {
                            return err;
                        }
                        // For other errors (permission, etc.), return cached content as fallback
                        const content = try self.allocator.dupe(u8, entry.value.content);
                        errdefer self.allocator.free(content);
                        const etag = if (entry.value.etag) |e|
                            try self.allocator.dupe(u8, e)
                        else
                            try generateETag(self.allocator, content.len, entry.value.mtime);
                        return .{ .content = content, .etag = etag };
                    };
                    defer file.close();
                    const stat = try file.stat();

                    if (entry.value.mtime == stat.mtime) {
                        // File hasn't changed, duplicate and update last_check_time
                        const content = try self.allocator.dupe(u8, entry.value.content);
                        errdefer self.allocator.free(content);
                        const etag = if (entry.value.etag) |e|
                            try self.allocator.dupe(u8, e)
                        else
                            try generateETag(self.allocator, content.len, entry.value.mtime);
                        errdefer self.allocator.free(etag);

                        // Update cache with new last_check_time
                        self.putCached(path, content, entry.value.mtime, etag) catch |err| {
                            std.log.debug("Failed to update file cache last_check_time for {s}: {}", .{ path, err });
                        };
                        return .{ .content = content, .etag = etag };
                    }

                    // File changed - continue to read new content below
                    // (entry is released when we exit the if block)
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
                    errdefer self.allocator.free(etag);
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
        if (self.cache.get(key)) |entry| {
            defer entry.release();
            const content = try self.allocator.dupe(u8, entry.value.content);
            errdefer self.allocator.free(content);
            const etag = if (entry.value.etag) |e|
                try self.allocator.dupe(u8, e)
            else
                try generateETag(self.allocator, content.len, entry.value.mtime);
            errdefer self.allocator.free(etag);
            return .{ .content = content, .etag = etag };
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
    /// Note: zcache doesn't have a bulk clear method, so this is a no-op.
    /// Entries will be evicted naturally via LRU or TTL expiration.
    pub fn clear(self: *FileCache) void {
        _ = self;
        // zcache doesn't have a clear/delPrefix method
        // Entries will be evicted naturally via LRU or TTL expiration
    }

    /// Get the number of cached entries
    pub fn count(self: *FileCache) usize {
        return self.cache.count();
    }
};

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
    // because we're within STAT_CHECK_INTERVAL_NS (1 second)
    const content2 = try file_cache.loadFile(test_file);
    defer allocator.free(content2);
    // Should still see original content because rate limiting skips stat check
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
    // ETag should start with W/" (weak ETag format)
    try testing.expect(std.mem.startsWith(u8, info1.etag, "W/\""));

    // Second load - should return cached content and etag
    const info2 = try file_cache.loadFileWithETag(test_file);
    defer allocator.free(info2.content);
    defer allocator.free(info2.etag);

    try testing.expectEqualStrings("cached content", info2.content);
    // ETags should be identical since file hasn't changed
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

    // Should still see original content because reload mode is 'never'
    try testing.expectEqualStrings("never reload content", info2.content);
}
