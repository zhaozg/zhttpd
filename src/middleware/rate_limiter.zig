const std = @import("std");

/// Rate limiting implementation using token bucket algorithm
/// Provides configurable request rate limiting per client IP or globally
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

        entry.tokens = @min(max_tokens, entry.tokens + @as(u32, @intCast(@min(refill_rate, @as(i64, max_tokens)))));
        entry.last_update = now;
    }

    /// Get remaining tokens for a client
    pub fn getRemainingTokens(self: *RateLimiter, client_ip: ?[]const u8) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.config.per_ip) {
            const ip = client_ip orelse return self.global_entry.tokens;
            if (self.entries.get(ip)) |entry| {
                return entry.tokens;
            }
            return self.config.max_requests + self.config.burst_size;
        } else {
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
