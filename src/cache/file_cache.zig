const std = @import("std");
const Config = @import("../config/config.zig");
const ReloadMode = Config.ReloadMode;

/// Cached file entry with content and modification time
pub const FileCacheEntry = struct {
    content: []const u8,
    mtime: i128, // File modification time in nanoseconds
};

/// Thread-safe file cache supporting multiple reload strategies
/// This cache can be used for any type of file: Lua scripts, static files, etc.
pub const FileCache = struct {
    map: std.StringHashMap(FileCacheEntry),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    reload_mode: ReloadMode,

    /// Initialize a new file cache with the specified reload mode
    pub fn init(allocator: std.mem.Allocator, reload_mode: ReloadMode) FileCache {
        return FileCache{
            .map = std.StringHashMap(FileCacheEntry).init(allocator),
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
            .reload_mode = reload_mode,
        };
    }

    /// Clean up all cached entries and free resources
    pub fn deinit(self: *FileCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.content);
        }
        self.map.deinit();
    }

    /// Get cached file content if available and valid according to reload mode
    /// Returns null if file is not cached or cache is invalid
    fn getCached(self: *FileCache, key: []const u8) ?FileCacheEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(key);
    }

    /// Update the cache with new file content and modification time
    fn putCached(self: *FileCache, key: []const u8, content: []const u8, mtime: i128) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // If entry already exists, free the old content and key
        if (self.map.fetchRemove(key)) |old_entry| {
            self.allocator.free(old_entry.key);
            self.allocator.free(old_entry.value.content);
        }

        // Store the new content with owned copies
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);

        try self.map.put(owned_key, FileCacheEntry{
            .content = owned_content,
            .mtime = mtime,
        });
    }

    /// Load file content with caching based on reload mode
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
                    return try self.allocator.dupe(u8, cached.content);
                }
                const content = try self.readFileFromDisk(path);
                // Cache with dummy mtime (we never check it in 'never' mode)
                try self.putCached(path, content, 0);
                return content;
            },
            .auto => {
                // Check file modification time
                const file = try std.fs.cwd().openFile(path, .{});
                defer file.close();
                const stat = try file.stat();
                const current_mtime = stat.mtime;

                // Check cache
                if (self.getCached(path)) |cached| {
                    if (cached.mtime == current_mtime) {
                        // File hasn't changed, use cache
                        return try self.allocator.dupe(u8, cached.content);
                    }
                }

                // File changed or not cached, read and update cache
                const content = try file.readToEndAlloc(self.allocator, 100 * 1024 * 1024); // 100MB max
                errdefer self.allocator.free(content);

                try self.putCached(path, content, current_mtime);
                return content;
            },
        }
    }

    /// Read file content from disk
    fn readFileFromDisk(self: *FileCache, path: []const u8) ![]const u8 {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        return try file.readToEndAlloc(self.allocator, 100 * 1024 * 1024); // 100MB max
    }

    /// Clear all cached entries (useful for testing or manual cache invalidation)
    pub fn clear(self: *FileCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.content);
        }
        self.map.clearRetainingCapacity();
    }

    /// Get the number of cached entries
    pub fn count(self: *FileCache) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.count();
    }
};

test "file cache init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = FileCache.init(allocator, .auto);
    defer cache.deinit();

    try testing.expect(cache.count() == 0);
}

test "file cache force mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = FileCache.init(allocator, .force);
    defer cache.deinit();

    // Create a temporary file
    const test_file = "test_cache_force.tmp";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("test content");
    }
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Load file twice - should read from disk both times
    const content1 = try cache.loadFile(test_file);
    defer allocator.free(content1);
    try testing.expectEqualStrings("test content", content1);

    // Even in force mode, cache count should be 0 as we don't cache
    try testing.expect(cache.count() == 0);
}
