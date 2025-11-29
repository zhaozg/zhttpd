const std = @import("std");
const Config = @import("../config/config.zig");
const ReloadMode = Config.ReloadMode;
const cache = @import("cache");

/// Maximum file size for reading (100MB)
const MAX_FILE_SIZE = 100 * 1024 * 1024;

/// Default file cache TTL in seconds (1 hour)
const DEFAULT_FILE_TTL: u32 = 3600;

/// Cached file entry with content, modification time, and ETag
pub const FileCacheEntry = struct {
    content: []const u8,
    mtime: i128, // File modification time in nanoseconds
    etag: ?[]const u8 = null, // ETag for cache validation
    allocator: std.mem.Allocator,

    /// Size estimation for cache eviction (in bytes)
    /// Required by cache.zig for size-based eviction
    pub fn size(self: FileCacheEntry) u32 {
        var total: u32 = @intCast(@min(self.content.len, std.math.maxInt(u32)));
        if (self.etag) |e| {
            total +|= @intCast(@min(e.len, std.math.maxInt(u32) - total));
        }
        return total;
    }

    /// Called by cache.zig when entry is removed from cache
    pub fn removedFromCache(self: *FileCacheEntry, _: std.mem.Allocator) void {
        // Use the entry's own allocator for cleanup
        self.allocator.free(self.content);
        if (self.etag) |e| {
            self.allocator.free(e);
        }
    }
};

/// Thread-safe file cache supporting multiple reload strategies
/// Uses cache.zig for LRU eviction and memory management
pub const FileCache = struct {
    cache: cache.Cache(FileCacheEntry),
    allocator: std.mem.Allocator,
    reload_mode: ReloadMode,
    max_cache_file_size: usize, // Maximum file size to cache (files larger than this won't be cached)

    /// Initialize a new file cache with the specified reload mode and max cache file size
    pub fn init(allocator: std.mem.Allocator, reload_mode: ReloadMode, max_cache_file_size: usize) FileCache {
        // Calculate max cache entries based on average file size assumption (10KB)
        const max_entries: u32 = @intCast(@min(max_cache_file_size / 10240 + 100, 10000));

        return FileCache{
            .cache = cache.Cache(FileCacheEntry).init(allocator, .{
                .max_size = max_entries,
                .segment_count = 8,
            }) catch {
                // Fallback to minimal cache on error
                return FileCache{
                    .cache = cache.Cache(FileCacheEntry).init(allocator, .{
                        .max_size = 100,
                        .segment_count = 1,
                    }) catch unreachable,
                    .allocator = allocator,
                    .reload_mode = reload_mode,
                    .max_cache_file_size = max_cache_file_size,
                };
            },
            .allocator = allocator,
            .reload_mode = reload_mode,
            .max_cache_file_size = max_cache_file_size,
        };
    }

    /// Clean up all cached entries and free resources
    pub fn deinit(self: *FileCache) void {
        self.cache.deinit();
    }

    /// Get cached file content if available and valid according to reload mode
    /// Returns null if file is not cached or cache is invalid
    fn getCached(self: *FileCache, key: []const u8) ?FileCacheEntry {
        if (self.cache.get(key)) |entry| {
            defer entry.release();
            return entry.value;
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
            .etag = owned_etag,
            .allocator = self.allocator,
        };

        try self.cache.put(key, entry, .{
            .ttl = DEFAULT_FILE_TTL,
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
                if (self.getCached(path)) |cached| {
                    // Note: We duplicate to give caller owned memory while keeping cached copy
                    return try self.allocator.dupe(u8, cached.content);
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
                // Check file modification time and size
                const file = try std.fs.cwd().openFile(path, .{});
                defer file.close();
                const stat = try file.stat();
                const current_mtime = stat.mtime;

                // If file is too large, don't cache it
                if (stat.size > self.max_cache_file_size) {
                    return try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                }

                // Check cache
                if (self.getCached(path)) |cached| {
                    if (cached.mtime == current_mtime) {
                        // File hasn't changed, use cache
                        // Note: We duplicate to give caller owned memory while keeping cached copy
                        return try self.allocator.dupe(u8, cached.content);
                    }
                }

                // File changed or not cached, read and update cache
                const content = try file.readToEndAlloc(self.allocator, MAX_FILE_SIZE);
                errdefer self.allocator.free(content);

                // Cache makes its own copy, so we can return the original
                try self.putCached(path, content, current_mtime, null);
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
        // cache.zig doesn't have a clear method, but we can delete by prefix with empty prefix
        _ = self.cache.delPrefix("") catch {};
    }

    /// Get the number of cached entries (approximate, for debugging)
    pub fn count(self: *FileCache) usize {
        // cache.zig doesn't expose count directly, return 0 for now
        _ = self;
        return 0;
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
