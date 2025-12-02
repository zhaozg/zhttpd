const std = @import("std");
const LruCache = @import("../cache/lru_cache.zig").LruCache;

/// Rate limiting implementation using token bucket algorithm
/// Provides configurable request rate limiting per client IP or globally
///
/// Note: This implementation stores per-IP entries indefinitely. For high-traffic
/// servers with many unique IPs, consider implementing periodic cleanup of stale
/// entries (e.g., entries older than window_seconds * N) or LRU eviction to
/// prevent unbounded memory growth.
pub const RateLimiter = struct {
    /// Rate limit configuration
    pub const Config = struct {
        /// Maximum requests allowed per window
        max_requests: u32 = 100,
        /// Time window in seconds
        window_seconds: u32 = 60,
        /// Enable per-IP rate limiting (vs global)
        per_ip: bool = true,
        /// Burst allowance (additional requests allowed in short bursts)
        burst_size: u32 = 10,
    };

    /// Rate limit entry for tracking requests
    const Entry = struct {
        tokens: u32,
        last_update: i64,
    };

    allocator: std.mem.Allocator,
    config: Config,
    entries: std.StringHashMap(Entry),
    global_entry: Entry,
    mutex: std.Thread.Mutex,

    /// Initialize a new rate limiter
    pub fn init(allocator: std.mem.Allocator, config: Config) RateLimiter {
        return RateLimiter{
            .allocator = allocator,
            .config = config,
            .entries = std.StringHashMap(Entry).init(allocator),
            .global_entry = Entry{
                .tokens = config.max_requests + config.burst_size,
                .last_update = std.time.timestamp(),
            },
            .mutex = std.Thread.Mutex{},
        };
    }

    /// Clean up resources
    pub fn deinit(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.entries.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.entries.deinit();
    }

    /// Check if a request is allowed and consume a token if so
    /// Returns true if request is allowed, false if rate limited
    pub fn checkRequest(self: *RateLimiter, client_ip: ?[]const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        if (self.config.per_ip) {
            const ip = client_ip orelse return self.checkGlobal(now);
            return self.checkPerIp(ip, now);
        } else {
            return self.checkGlobal(now);
        }
    }

    fn checkGlobal(self: *RateLimiter, now: i64) bool {
        self.refillTokens(&self.global_entry, now);

        if (self.global_entry.tokens > 0) {
            self.global_entry.tokens -= 1;
            return true;
        }
        return false;
    }

    fn checkPerIp(self: *RateLimiter, ip: []const u8, now: i64) bool {
        if (self.entries.getPtr(ip)) |entry| {
            self.refillTokens(entry, now);

            if (entry.tokens > 0) {
                entry.tokens -= 1;
                return true;
            }
            return false;
        }

        // New IP, create entry
        const owned_ip = self.allocator.dupe(u8, ip) catch return false;
        const entry = Entry{
            .tokens = self.config.max_requests + self.config.burst_size - 1, // -1 for current request
            .last_update = now,
        };
        self.entries.put(owned_ip, entry) catch {
            self.allocator.free(owned_ip);
            return false;
        };
        return true;
    }

    fn refillTokens(self: *RateLimiter, entry: *Entry, now: i64) void {
        const elapsed = now - entry.last_update;
        if (elapsed <= 0) return;

        // Calculate tokens to add based on elapsed time
        const window: i64 = @intCast(self.config.window_seconds);
        const max_tokens: u32 = self.config.max_requests + self.config.burst_size;
        const refill_rate: i64 = @divFloor(@as(i64, max_tokens) * elapsed, window);

        // Clamp refill amount to max_tokens to prevent overflow
        const clamped_refill: i64 = @min(refill_rate, @as(i64, max_tokens));
        const refill_amount: u32 = @intCast(clamped_refill);

        // Calculate new token count, clamped to max
        const new_tokens = entry.tokens + refill_amount;
        entry.tokens = @min(max_tokens, new_tokens);
        entry.last_update = now;
    }

    /// Get remaining tokens for a client
    /// Note: Refills tokens based on elapsed time before returning count
    pub fn getRemainingTokens(self: *RateLimiter, client_ip: ?[]const u8) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        if (self.config.per_ip) {
            const ip = client_ip orelse {
                self.refillTokens(&self.global_entry, now);
                return self.global_entry.tokens;
            };
            if (self.entries.getPtr(ip)) |entry| {
                self.refillTokens(entry, now);
                return entry.tokens;
            }
            return self.config.max_requests + self.config.burst_size;
        } else {
            self.refillTokens(&self.global_entry, now);
            return self.global_entry.tokens;
        }
    }

    /// Clear all entries (useful for testing)
    pub fn clear(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.entries.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.entries.clearRetainingCapacity();

        self.global_entry = Entry{
            .tokens = self.config.max_requests + self.config.burst_size,
            .last_update = std.time.timestamp(),
        };
    }
};

// ============================================================================
// IP Blacklist / Whitelist Manager
// ============================================================================

/// IP access control result
pub const IpAccessResult = enum {
    /// IP is allowed (not in blacklist, or in whitelist)
    allowed,
    /// IP is blocked (in blacklist)
    blocked,
    /// IP is whitelisted (bypasses rate limiting)
    whitelisted,
};

/// IP-based access control with blacklist and whitelist support
/// Supports exact IP matching and CIDR notation for subnets
///
/// Optimization: This implementation uses an LRU cache to avoid repeated
/// IP access checks for the same IP addresses. This is particularly beneficial
/// for persistent connections (HTTP keep-alive, WebSocket, SSE) where the same
/// IP makes many requests over time.
///
/// The cache stores up to 10,000 IP access decisions by default, which provides
/// significant performance improvement for long-lived connections and high-traffic
/// scenarios while using minimal memory (~200KB).
///
/// Thread Safety and Lock Ordering:
/// - The IpAccessControl mutex protects the blacklist/whitelist entries
/// - The LRU cache has its own internal mutex for thread safety
/// - Lock ordering: IpAccessControl mutex is always acquired before cache mutex
/// - Cache operations are performed inside the main mutex to prevent race conditions
///   where the blacklist/whitelist could change between cache check and list iteration
pub const IpAccessControl = struct {
    /// Configuration for IP access control
    pub const Config = struct {
        /// Enable IP access control
        enabled: bool = false,
        /// Comma-separated list of blacklisted IPs or CIDR ranges
        blacklist: []const u8 = "",
        /// Comma-separated list of whitelisted IPs or CIDR ranges
        whitelist: []const u8 = "",
        /// Block requests from private/internal IPs when behind proxy
        /// (trust X-Forwarded-For or X-Real-IP headers)
        trust_proxy_headers: bool = false,
        /// Log blocked requests
        log_blocked: bool = true,
        /// Maximum number of IP access decisions to cache (default: 10000)
        /// Set to 0 to disable caching (not recommended for production)
        cache_size: usize = 10000,
    };

    config: Config,
    /// Parsed blacklist entries
    blacklist_entries: std.ArrayList(IpEntry),
    /// Parsed whitelist entries
    whitelist_entries: std.ArrayList(IpEntry),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    /// LRU cache for IP access decisions (optimization for persistent connections)
    access_cache: ?LruCache([]const u8, IpAccessResult, void),

    /// IP entry (single IP or CIDR range)
    pub const IpEntry = struct {
        /// IP address or network address
        ip: [4]u8,
        /// Subnet mask (255.255.255.255 for single IP)
        mask: [4]u8,
        /// Original string representation
        original: []const u8,

        /// Check if an IP matches this entry
        pub fn matches(self: *const IpEntry, ip_bytes: [4]u8) bool {
            for (0..4) |i| {
                if ((ip_bytes[i] & self.mask[i]) != (self.ip[i] & self.mask[i])) {
                    return false;
                }
            }
            return true;
        }
    };

    /// Initialize IP access control
    pub fn init(allocator: std.mem.Allocator, config: Config) !IpAccessControl {
        var control = IpAccessControl{
            .config = config,
            .blacklist_entries = std.ArrayList(IpEntry){},
            .whitelist_entries = std.ArrayList(IpEntry){},
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .access_cache = null,
        };

        // Initialize LRU cache if cache size > 0
        if (config.cache_size > 0) {
            const cache_config = @import("../cache/lru_cache.zig").CacheConfig{
                .max_size = config.cache_size,
                .default_ttl_ms = 0, // No expiration - invalidate on config change
            };
            control.access_cache = LruCache([]const u8, IpAccessResult, void).init(
                allocator,
                cache_config,
                {},
                null,
            );
        }

        // Parse blacklist
        if (config.blacklist.len > 0) {
            try control.parseIpList(config.blacklist, &control.blacklist_entries);
        }

        // Parse whitelist
        if (config.whitelist.len > 0) {
            try control.parseIpList(config.whitelist, &control.whitelist_entries);
        }

        return control;
    }

    /// Clean up resources
    pub fn deinit(self: *IpAccessControl) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up cache if it exists
        if (self.access_cache) |*cache| {
            cache.deinit();
        }

        for (self.blacklist_entries.items) |entry| {
            self.allocator.free(entry.original);
        }
        self.blacklist_entries.deinit(self.allocator);

        for (self.whitelist_entries.items) |entry| {
            self.allocator.free(entry.original);
        }
        self.whitelist_entries.deinit(self.allocator);
    }

    /// Parse a comma-separated list of IPs/CIDRs
    fn parseIpList(self: *IpAccessControl, list: []const u8, entries: *std.ArrayList(IpEntry)) !void {
        var it = std.mem.splitSequence(u8, list, ",");
        while (it.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " \t");
            if (trimmed.len == 0) continue;

            if (parseIpEntry(trimmed)) |entry| {
                var entry_copy = entry;
                entry_copy.original = try self.allocator.dupe(u8, trimmed);
                try entries.append(self.allocator, entry_copy);
            }
        }
    }

    /// Check if an IP is allowed
    /// Optimized with LRU cache to avoid repeated checks for the same IP,
    /// especially beneficial for long-lived connections (keep-alive, WebSocket, SSE)
    pub fn checkAccess(self: *IpAccessControl, ip_str: []const u8) IpAccessResult {
        if (!self.config.enabled) {
            return .allowed;
        }

        // Acquire lock once for entire operation to avoid race conditions
        // between cache check and list iteration
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try cache first if enabled (optimization for persistent connections)
        // Note: Cache lookup is done inside mutex to prevent race conditions
        // where blacklist/whitelist could change between cache check and list iteration
        if (self.access_cache) |*cache| {
            if (cache.getPtr(ip_str)) |result| {
                defer result.entry.release();
                return result.value.*;
            }
        }

        // Parse the IP address
        const ip_bytes = parseIpAddress(ip_str) orelse return .allowed;

        // Check whitelist first (whitelisted IPs bypass all checks)
        for (self.whitelist_entries.items) |*entry| {
            if (entry.matches(ip_bytes)) {
                // Cache the decision before returning
                // Note: Cache operations are done inside the main mutex to maintain
                // consistency. The LRU cache has its own internal mutex, but this
                // is acceptable as the cache mutex is always acquired after the
                // IP access control mutex (consistent lock ordering).
                if (self.access_cache) |*cache| {
                    // Silently ignore cache failures as they don't affect correctness
                    // Cache failures indicate memory pressure or cache corruption
                    // but the IP check result is still valid
                    cache.put(ip_str, .whitelisted) catch {};
                }
                return .whitelisted;
            }
        }

        // Check blacklist
        for (self.blacklist_entries.items) |*entry| {
            if (entry.matches(ip_bytes)) {
                // Cache the decision before returning
                if (self.access_cache) |*cache| {
                    cache.put(ip_str, .blocked) catch {};
                }
                return .blocked;
            }
        }

        // Cache the allowed decision
        if (self.access_cache) |*cache| {
            cache.put(ip_str, .allowed) catch {};
        }

        return .allowed;
    }

    /// Add an IP to the blacklist at runtime
    /// Clears the cache to ensure consistency
    pub fn addToBlacklist(self: *IpAccessControl, ip_str: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (parseIpEntry(ip_str)) |entry| {
            var entry_copy = entry;
            entry_copy.original = try self.allocator.dupe(u8, ip_str);
            try self.blacklist_entries.append(self.allocator, entry_copy);

            // Invalidate cache since blacklist changed
            if (self.access_cache) |*cache| {
                cache.clear();
            }
        }
    }

    /// Remove an IP from the blacklist
    /// Clears the cache to ensure consistency
    pub fn removeFromBlacklist(self: *IpAccessControl, ip_str: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        var changed = false;
        while (i < self.blacklist_entries.items.len) {
            if (std.mem.eql(u8, self.blacklist_entries.items[i].original, ip_str)) {
                self.allocator.free(self.blacklist_entries.items[i].original);
                _ = self.blacklist_entries.orderedRemove(i);
                changed = true;
            } else {
                i += 1;
            }
        }

        // Invalidate cache if blacklist changed
        if (changed) {
            if (self.access_cache) |*cache| {
                cache.clear();
            }
        }
    }

    /// Add an IP to the whitelist at runtime
    /// Clears the cache to ensure consistency
    pub fn addToWhitelist(self: *IpAccessControl, ip_str: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (parseIpEntry(ip_str)) |entry| {
            var entry_copy = entry;
            entry_copy.original = try self.allocator.dupe(u8, ip_str);
            try self.whitelist_entries.append(self.allocator, entry_copy);

            // Invalidate cache since whitelist changed
            if (self.access_cache) |*cache| {
                cache.clear();
            }
        }
    }

    /// Get the number of blacklisted entries
    pub fn getBlacklistCount(self: *IpAccessControl) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.blacklist_entries.items.len;
    }

    /// Get the number of whitelisted entries
    pub fn getWhitelistCount(self: *IpAccessControl) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.whitelist_entries.items.len;
    }

    /// Get cache statistics for monitoring (returns null if caching is disabled)
    pub fn getCacheStats(self: *IpAccessControl) ?struct { size: usize, max_size: usize } {
        if (self.access_cache) |*cache| {
            return .{
                .size = cache.getCount(),
                .max_size = self.config.cache_size,
            };
        }
        return null;
    }

    /// Clear the IP access cache (useful when configuration changes)
    pub fn clearCache(self: *IpAccessControl) void {
        if (self.access_cache) |*cache| {
            cache.clear();
        }
    }
};

/// Parse an IP address string to bytes (IPv4 only)
fn parseIpAddress(ip_str: []const u8) ?[4]u8 {
    // Handle IP:port format (strip port)
    const ip_part = if (std.mem.indexOf(u8, ip_str, ":")) |colon_pos|
        ip_str[0..colon_pos]
    else
        ip_str;

    var result: [4]u8 = undefined;
    var octet_index: usize = 0;
    var current_value: u16 = 0;
    var has_digit = false;

    for (ip_part) |c| {
        if (c == '.') {
            if (!has_digit or octet_index >= 3) return null;
            if (current_value > 255) return null;
            result[octet_index] = @intCast(current_value);
            octet_index += 1;
            current_value = 0;
            has_digit = false;
        } else if (c >= '0' and c <= '9') {
            current_value = current_value * 10 + (c - '0');
            has_digit = true;
        } else {
            return null; // Invalid character
        }
    }

    // Final octet
    if (!has_digit or octet_index != 3) return null;
    if (current_value > 255) return null;
    result[octet_index] = @intCast(current_value);

    return result;
}

/// Parse an IP entry (IP or CIDR notation)
fn parseIpEntry(entry_str: []const u8) ?IpAccessControl.IpEntry {
    // Check for CIDR notation
    if (std.mem.indexOf(u8, entry_str, "/")) |slash_pos| {
        const ip_part = entry_str[0..slash_pos];
        const prefix_part = entry_str[slash_pos + 1 ..];

        const ip_bytes = parseIpAddress(ip_part) orelse return null;
        const prefix_len = std.fmt.parseInt(u8, prefix_part, 10) catch return null;

        if (prefix_len > 32) return null;

        // Calculate subnet mask from prefix length
        var mask: [4]u8 = [_]u8{ 0, 0, 0, 0 };
        var bits_remaining: u8 = prefix_len;
        for (0..4) |i| {
            if (bits_remaining >= 8) {
                mask[i] = 255;
                bits_remaining -= 8;
            } else if (bits_remaining > 0) {
                mask[i] = @as(u8, 255) << @intCast(8 - bits_remaining);
                bits_remaining = 0;
            }
        }

        return IpAccessControl.IpEntry{
            .ip = ip_bytes,
            .mask = mask,
            .original = "",
        };
    } else {
        // Single IP address
        const ip_bytes = parseIpAddress(entry_str) orelse return null;
        return IpAccessControl.IpEntry{
            .ip = ip_bytes,
            .mask = [_]u8{ 255, 255, 255, 255 },
            .original = "",
        };
    }
}

// Tests
test "rate limiter basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var limiter = RateLimiter.init(allocator, .{
        .max_requests = 5,
        .window_seconds = 60,
        .per_ip = false,
        .burst_size = 2,
    });
    defer limiter.deinit();

    // Should allow max_requests + burst_size requests
    var allowed: u32 = 0;
    for (0..10) |_| {
        if (limiter.checkRequest(null)) {
            allowed += 1;
        }
    }
    try testing.expect(allowed == 7); // 5 + 2 burst
}

test "rate limiter per ip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var limiter = RateLimiter.init(allocator, .{
        .max_requests = 3,
        .window_seconds = 60,
        .per_ip = true,
        .burst_size = 0,
    });
    defer limiter.deinit();

    // Different IPs should have separate limits
    try testing.expect(limiter.checkRequest("192.168.1.1") == true);
    try testing.expect(limiter.checkRequest("192.168.1.1") == true);
    try testing.expect(limiter.checkRequest("192.168.1.1") == true);
    try testing.expect(limiter.checkRequest("192.168.1.1") == false); // Rate limited

    // Different IP should still have tokens
    try testing.expect(limiter.checkRequest("192.168.1.2") == true);
}

test "parse ip address" {
    const testing = std.testing;

    // Valid IPs
    const ip1 = parseIpAddress("192.168.1.1");
    try testing.expect(ip1 != null);
    try testing.expectEqual([4]u8{ 192, 168, 1, 1 }, ip1.?);

    const ip2 = parseIpAddress("10.0.0.1");
    try testing.expect(ip2 != null);
    try testing.expectEqual([4]u8{ 10, 0, 0, 1 }, ip2.?);

    // IP with port
    const ip3 = parseIpAddress("192.168.1.1:8080");
    try testing.expect(ip3 != null);
    try testing.expectEqual([4]u8{ 192, 168, 1, 1 }, ip3.?);

    // Invalid IPs
    try testing.expect(parseIpAddress("invalid") == null);
    try testing.expect(parseIpAddress("256.1.1.1") == null);
    try testing.expect(parseIpAddress("1.2.3") == null);
}

test "parse ip entry cidr" {
    const testing = std.testing;

    // Single IP
    const entry1 = parseIpEntry("192.168.1.1");
    try testing.expect(entry1 != null);
    try testing.expectEqual([4]u8{ 192, 168, 1, 1 }, entry1.?.ip);
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, entry1.?.mask);

    // /24 subnet
    const entry2 = parseIpEntry("192.168.1.0/24");
    try testing.expect(entry2 != null);
    try testing.expectEqual([4]u8{ 192, 168, 1, 0 }, entry2.?.ip);
    try testing.expectEqual([4]u8{ 255, 255, 255, 0 }, entry2.?.mask);

    // /16 subnet
    const entry3 = parseIpEntry("10.0.0.0/16");
    try testing.expect(entry3 != null);
    try testing.expectEqual([4]u8{ 10, 0, 0, 0 }, entry3.?.ip);
    try testing.expectEqual([4]u8{ 255, 255, 0, 0 }, entry3.?.mask);

    // /8 subnet
    const entry4 = parseIpEntry("10.0.0.0/8");
    try testing.expect(entry4 != null);
    try testing.expectEqual([4]u8{ 255, 0, 0, 0 }, entry4.?.mask);
}

test "ip entry matching" {
    const testing = std.testing;

    // Single IP matching
    const entry1 = parseIpEntry("192.168.1.100").?;
    try testing.expect(entry1.matches([4]u8{ 192, 168, 1, 100 }) == true);
    try testing.expect(entry1.matches([4]u8{ 192, 168, 1, 101 }) == false);

    // CIDR matching
    const entry2 = parseIpEntry("192.168.1.0/24").?;
    try testing.expect(entry2.matches([4]u8{ 192, 168, 1, 0 }) == true);
    try testing.expect(entry2.matches([4]u8{ 192, 168, 1, 255 }) == true);
    try testing.expect(entry2.matches([4]u8{ 192, 168, 2, 1 }) == false);
}

test "ip access control" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var control = try IpAccessControl.init(allocator, .{
        .enabled = true,
        .blacklist = "192.168.1.100, 10.0.0.0/8",
        .whitelist = "192.168.1.1",
    });
    defer control.deinit();

    // Whitelisted IP
    try testing.expect(control.checkAccess("192.168.1.1") == .whitelisted);

    // Blacklisted exact IP
    try testing.expect(control.checkAccess("192.168.1.100") == .blocked);

    // Blacklisted by CIDR
    try testing.expect(control.checkAccess("10.5.3.2") == .blocked);

    // Not in any list
    try testing.expect(control.checkAccess("8.8.8.8") == .allowed);
}

test "ip access control dynamic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var control = try IpAccessControl.init(allocator, .{
        .enabled = true,
        .blacklist = "",
        .whitelist = "",
    });
    defer control.deinit();

    // Initially allowed
    try testing.expect(control.checkAccess("192.168.1.50") == .allowed);

    // Add to blacklist
    try control.addToBlacklist("192.168.1.50");
    try testing.expect(control.checkAccess("192.168.1.50") == .blocked);
    try testing.expect(control.getBlacklistCount() == 1);

    // Add to whitelist (whitelist takes precedence)
    try control.addToWhitelist("192.168.1.50");
    try testing.expect(control.checkAccess("192.168.1.50") == .whitelisted);

    // Remove from blacklist
    control.removeFromBlacklist("192.168.1.50");
    try testing.expect(control.getBlacklistCount() == 0);
}

test "ip access control caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Initialize with cache enabled (default)
    var control = try IpAccessControl.init(allocator, .{
        .enabled = true,
        .blacklist = "192.168.1.100",
        .whitelist = "192.168.1.1",
        .cache_size = 100, // Small cache for testing
    });
    defer control.deinit();

    // First access - should check and cache
    try testing.expect(control.checkAccess("192.168.1.1") == .whitelisted);
    try testing.expect(control.checkAccess("192.168.1.100") == .blocked);
    try testing.expect(control.checkAccess("192.168.1.50") == .allowed);

    // Second access - should hit cache
    try testing.expect(control.checkAccess("192.168.1.1") == .whitelisted);
    try testing.expect(control.checkAccess("192.168.1.100") == .blocked);
    try testing.expect(control.checkAccess("192.168.1.50") == .allowed);

    // Verify cache stats
    if (control.getCacheStats()) |stats| {
        try testing.expect(stats.size == 3); // Three unique IPs cached
        try testing.expect(stats.max_size == 100);
    } else {
        try testing.expect(false); // Cache should be enabled
    }

    // Add to blacklist should clear cache
    try control.addToBlacklist("192.168.1.50");
    if (control.getCacheStats()) |stats| {
        try testing.expect(stats.size == 0); // Cache should be cleared
    }

    // After blacklist update, should check fresh
    try testing.expect(control.checkAccess("192.168.1.50") == .blocked);
}

test "ip access control no caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Initialize with cache disabled
    var control = try IpAccessControl.init(allocator, .{
        .enabled = true,
        .blacklist = "192.168.1.100",
        .cache_size = 0, // Disable caching
    });
    defer control.deinit();

    // Should work without cache
    try testing.expect(control.checkAccess("192.168.1.100") == .blocked);
    try testing.expect(control.checkAccess("192.168.1.1") == .allowed);

    // Cache stats should return null
    try testing.expect(control.getCacheStats() == null);
}
