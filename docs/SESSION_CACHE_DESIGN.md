# Session Management and Cache Integration Design

## Overview

This document outlines the design for integrating the [cache.zig](https://github.com/karlseguin/cache.zig) library into zhttpd for:

1. **Object Cache Management** - Thread-safe, LRU-based caching for general objects
2. **Session Management** - In-memory session storage with configurable TTL
3. **Database Connection Pool Optimization** - Cache-based connection tracking

## Design Goals

1. **Thread Safety** - All cache operations must be safe for concurrent access
2. **Interoperability** - Session objects must work seamlessly between Zig and Lua
3. **Flexibility** - Support both in-memory caching (default) with future Redis extensibility
4. **Value Type Diversity** - Reuse concepts from YAML Value for multi-type support
5. **Zero-Copy Where Possible** - Minimize memory allocations in hot paths

---

## 1. Cache.zig Integration

### 1.1 Dependency Addition

Add cache.zig to `build.zig.zon`:

```zig
.cache = .{
    .url = "https://github.com/karlseguin/cache.zig/archive/9f3329b05b3e98da928fe9988d74971da70328b4.tar.gz",
    .hash = "...",
},
```

### 1.2 File Cache with cache.zig

The `FileCache` uses cache.zig for thread-safe LRU file content caching:

```zig
pub const FileCacheEntry = struct {
    content: []const u8,
    mtime: i128,
    etag: ?[]const u8,
    allocator: std.mem.Allocator,

    /// Size for cache eviction
    pub fn size(self: FileCacheEntry) u32 {
        var total: u32 = @intCast(self.content.len);
        if (self.etag) |e| total +|= @intCast(e.len);
        return total;
    }

    /// Called by cache.zig on eviction
    pub fn removedFromCache(self: *FileCacheEntry, _: std.mem.Allocator) void {
        self.allocator.free(self.content);
        if (self.etag) |e| self.allocator.free(e);
    }
};

pub const FileCache = struct {
    cache: cache.Cache(FileCacheEntry),
    allocator: std.mem.Allocator,
    reload_mode: ReloadMode,
    max_cache_file_size: usize,
};
```

Benefits of using cache.zig for file cache:
- Automatic LRU eviction when memory limit reached
- Thread-safe segment-based locking
- TTL support for automatic refresh
- Size-based eviction using actual file sizes

---

## 2. Session Value Type

### 2.1 Design Rationale

Session values support primitive types for simplicity:
- Strings (binary-safe - supports arbitrary bytes including null)
- Integers (counters, timestamps)
- Floats (metrics)
- Booleans (flags)
- Null

**Binary Data Support**: Lua strings can contain arbitrary binary data including null bytes.
This is fully supported on the Zig side using length-based string operations.

**Note**: For complex objects (arrays, nested objects), use JSON strings.
This simplifies implementation while maintaining flexibility via cjson.encode()/cjson.decode() in Lua.

### 2.2 Session Value Definition

```zig
/// Session value type supporting primitive data types
/// Strings are binary-safe (can contain null bytes)
pub const SessionValue = union(enum) {
    null: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,  // Binary-safe, length-based
    
    /// Size estimation for cache eviction (bytes)
    pub fn size(self: SessionValue) u32 {
        return switch (self) {
            .null, .boolean => 1,
            .integer, .float => 8,
            .string => |s| @intCast(s.len + 1),
        };
    }
};
```

### 2.3 Complex Objects as JSON

For storing complex data in sessions, use JSON strings:

```lua
-- Store complex object as JSON
local user_data = { name = "John", roles = {"admin", "user"} }
session:set("user", cjson.encode(user_data))

-- Retrieve and decode
local user = cjson.decode(session:get("user"))
print(user.name)  -- "John"
```

### 2.4 Comparison with YAML Value

| Aspect | YAML Value | Session Value | Notes |
|--------|-----------|---------------|-------|
| Purpose | Config parsing | Runtime state | Different lifecycles |
| Mutability | Immutable after parse | Mutable | Sessions need updates |
| Complex types | Native support | JSON strings | Simpler implementation |
| Allocation | Arena | Heap + manual | Sessions need explicit cleanup |

---

## 3. Session Management Architecture

### 3.1 Session Structure

```zig
/// A session contains user-defined key-value data
pub const Session = struct {
    id: []const u8,                           // Session ID (e.g., UUID)
    data: std.StringHashMap(SessionValue),    // Session data
    created_at: i64,                          // Unix timestamp
    last_accessed: i64,                       // For access tracking
    
    /// Size for cache eviction
    pub fn size(self: *const Session) u32 {
        var total: u32 = @intCast(self.id.len);
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            total += @intCast(entry.key_ptr.*.len);
            total += entry.value_ptr.size();
        }
        return total;
    }
    
    pub fn removedFromCache(self: *Session, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }
};
```

### 3.2 Session Manager

```zig
const cache = @import("cache");

/// Global session manager using cache.zig
pub const SessionManager = struct {
    cache: cache.Cache(Session),
    allocator: std.mem.Allocator,
    default_ttl: u32,           // Default session TTL in seconds
    
    pub fn init(allocator: std.mem.Allocator, config: SessionConfig) !SessionManager {
        return SessionManager{
            .cache = try cache.Cache(Session).init(allocator, .{
                .max_size = config.max_sessions,
                .segment_count = 8,  // Good for concurrent access
            }),
            .allocator = allocator,
            .default_ttl = config.default_ttl,
        };
    }
    
    /// Get or create session
    pub fn getOrCreate(self: *SessionManager, session_id: []const u8) !*Session { ... }
    
    /// Get existing session
    pub fn get(self: *SessionManager, session_id: []const u8) ?*Session { ... }
    
    /// Set session value
    pub fn set(self: *SessionManager, session_id: []const u8, key: []const u8, value: SessionValue) !void { ... }
    
    /// Delete session
    pub fn delete(self: *SessionManager, session_id: []const u8) bool { ... }
};
```

### 3.3 Session Configuration

```yaml
# zhttpd.yaml
session:
  enabled: true
  max_sessions: 10000      # Maximum number of sessions
  default_ttl: 1800        # 30 minutes default TTL
  cookie_name: "ZHTTPD_SESSION"
  cookie_secure: true      # HTTPS only
  cookie_http_only: true   # Prevent XSS
```

---

## 4. Lua API for Sessions

### 4.1 Session Access from Lua

Sessions are accessed via the context object:

```lua
function handle(request, response, context)
    -- Get session (auto-created if not exists)
    local session = context:session()
    
    -- Get session ID
    local sid = session:id()
    
    -- Get/Set values
    local user_id = session:get("user_id")
    session:set("user_id", 12345)
    session:set("logged_in", true)
    session:set("name", "John Doe")
    
    -- Delete specific key
    session:delete("temp_data")
    
    -- Clear all session data
    session:clear()
    
    -- Destroy session completely
    session:destroy()
    
    return { status = "ok", session_id = sid }
end
```

### 4.2 Lua Bindings Implementation

```zig
// Register session metatable
fn registerSessionMetatable(lua: *ziglua.Lua) void {
    lua.newMetatable("zhttpd.session") catch return;
    
    lua.pushValue(-1);
    lua.setField(-2, "__index");
    
    lua.pushFunction(ziglua.wrap(sessionId));
    lua.setField(-2, "id");
    
    lua.pushFunction(ziglua.wrap(sessionGet));
    lua.setField(-2, "get");
    
    lua.pushFunction(ziglua.wrap(sessionSet));
    lua.setField(-2, "set");
    
    lua.pushFunction(ziglua.wrap(sessionDelete));
    lua.setField(-2, "delete");
    
    lua.pushFunction(ziglua.wrap(sessionClear));
    lua.setField(-2, "clear");
    
    lua.pushFunction(ziglua.wrap(sessionDestroy));
    lua.setField(-2, "destroy");
    
    lua.pop(1);
}

/// context:session() - Get/create session
fn contextSession(lua: *ziglua.Lua) i32 {
    // 1. Get session ID from cookie or generate new
    // 2. Get or create session from SessionManager
    // 3. Push session userdata with metatable
    // 4. Set session cookie in response if new
}
```

### 4.3 SessionValue to Lua Conversion

```zig
fn pushSessionValueToLua(lua: *ziglua.Lua, value: SessionValue) void {
    switch (value) {
        .null => lua.pushNil(),
        .boolean => |b| lua.pushBoolean(b),
        .integer => |i| lua.pushInteger(i),
        .float => |f| lua.pushNumber(f),
        .string => |s| _ = lua.pushString(s),
        .array => |a| {
            lua.newTable();
            for (a, 1..) |item, idx| {
                pushSessionValueToLua(lua, item);
                lua.rawSetIndex(-2, @intCast(idx));
            }
        },
        .object => |o| {
            lua.newTable();
            var iter = o.iterator();
            while (iter.next()) |entry| {
                pushSessionValueToLua(lua, entry.value_ptr.*);
                // Set field with key
            }
        },
    }
}

fn luaValueToSessionValue(lua: *ziglua.Lua, idx: i32, allocator: std.mem.Allocator) !SessionValue {
    return switch (lua.typeOf(idx)) {
        .nil => .{ .null = {} },
        .boolean => .{ .boolean = lua.toBoolean(idx) },
        .number => blk: {
            const num = lua.toNumber(idx) catch break :blk .{ .null = {} };
            const int_val = lua.toInteger(idx) catch break :blk .{ .float = num };
            if (@as(f64, @floatFromInt(int_val)) == num) {
                break :blk .{ .integer = int_val };
            }
            break :blk .{ .float = num };
        },
        .string => .{ .string = try allocator.dupe(u8, lua.toString(idx) catch "") },
        .table => // Convert recursively
        else => .{ .null = {} },
    };
}
```

---

## 5. Database Connection Pool with Cache

### 5.1 Connection Pool Design

While zdbc handles basic connections, cache.zig can help with:
- Connection state tracking
- Idle connection cleanup
- Connection metrics

```zig
/// Connection wrapper for cache management
pub const CachedConnection = struct {
    connection: *zdbc.Connection,
    created_at: i64,
    last_used: i64,
    query_count: u64,
    
    pub fn size(self: CachedConnection) u32 {
        return 1; // Each connection counts as 1 unit
    }
    
    pub fn removedFromCache(self: *CachedConnection, _: std.mem.Allocator) void {
        self.connection.close();
    }
};

pub const ConnectionPool = struct {
    cache: cache.Cache(CachedConnection),
    uri: []const u8,
    max_connections: u32,
    
    pub fn init(allocator: std.mem.Allocator, uri: []const u8, pool_size: u32) !ConnectionPool {
        return ConnectionPool{
            .cache = try cache.Cache(CachedConnection).init(allocator, .{
                .max_size = pool_size,
                .segment_count = 4,
                .gets_per_promote = 1,  // Always promote on use
            }),
            .uri = uri,
            .max_connections = pool_size,
        };
    }
    
    /// Get or create a connection
    pub fn acquire(self: *ConnectionPool) !*zdbc.Connection {
        // Check for idle connection in cache
        // If not found, create new connection
        // Track usage
    }
    
    /// Return connection to pool
    pub fn release(self: *ConnectionPool, conn: *zdbc.Connection) void {
        // Update last_used timestamp
        // Put back in cache
    }
};
```

### 5.2 Integration with DbManager

```zig
// In DbManager.init()
pub fn init(allocator: std.mem.Allocator, configs: []const DataSourceConfig) !Self {
    // For each data source, create a ConnectionPool with cache
    for (configs) |cfg| {
        const pool = try ConnectionPool.init(allocator, cfg.uri, cfg.pool_size);
        // Store pool for the data source
    }
}
```

---

## 6. Global Cache Configuration

### 6.1 Configuration Schema

```yaml
# zhttpd.yaml additions
cache:
  # Session cache configuration
  session:
    enabled: true
    max_sessions: 10000
    default_ttl: 1800          # 30 minutes
    segment_count: 8
    
  # Database connection pool
  db_pool:
    enabled: true
    idle_timeout: 300          # 5 minutes idle before cleanup
    max_idle_per_source: 10
    
  # General object cache (for Lua scripts)
  objects:
    enabled: true
    max_size: 50000
    default_ttl: 3600          # 1 hour
```

### 6.2 CacheConfig Structure

```zig
pub const CacheConfig = struct {
    // Session configuration
    session_enabled: bool = true,
    session_max_size: u32 = 10000,
    session_default_ttl: u32 = 1800,
    session_segment_count: u16 = 8,
    session_cookie_name: []const u8 = "ZHTTPD_SESSION",
    session_cookie_secure: bool = true,
    session_cookie_http_only: bool = true,
    
    // DB pool configuration
    db_pool_enabled: bool = true,
    db_pool_idle_timeout: u32 = 300,
    db_pool_max_idle: u32 = 10,
    
    // Object cache configuration
    object_cache_enabled: bool = true,
    object_cache_max_size: u32 = 50000,
    object_cache_default_ttl: u32 = 3600,
};
```

---

## 7. Thread Safety Considerations

### 7.1 Cache.zig Thread Safety

Cache.zig provides built-in thread safety through:
- Segment-based locking (configurable segment count)
- Atomic reference counting for entries
- Lock-free promotion (after N gets)

### 7.2 Session Access Pattern

```
Request Thread 1                  Request Thread 2
      |                                |
      v                                v
[Get Session "abc123"]          [Get Session "xyz789"]
      |                                |
      v                                v
[Cache Segment 3]               [Cache Segment 7]  <- Different segments
      |                                |
      v                                v
[Process Request]               [Process Request]
      |                                |
      v                                v
[Update Session]                [Update Session]
      |                                |
      v                                v
[Release Entry]                 [Release Entry]
```

### 7.3 Session ID Generation

```zig
const std = @import("std");

pub fn generateSessionId() ![32]u8 {
    var buf: [16]u8 = undefined;
    std.crypto.random.bytes(&buf);
    
    var result: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x}", .{std.fmt.fmtSliceHexLower(&buf)}) catch unreachable;
    return result;
}
```

---

## 8. Future Extensibility: Redis Backend

### 8.1 Storage Backend Interface

```zig
/// Abstract storage backend for sessions
pub const SessionStore = union(enum) {
    memory: *MemoryStore,
    redis: *RedisStore,      // Future implementation
    
    pub fn get(self: SessionStore, key: []const u8) !?Session { ... }
    pub fn put(self: SessionStore, key: []const u8, session: Session, ttl: u32) !void { ... }
    pub fn delete(self: SessionStore, key: []const u8) bool { ... }
};

/// In-memory store using cache.zig (default implementation)
pub const MemoryStore = struct {
    cache: cache.Cache(Session),
    ...
};

/// Redis store (future implementation)
pub const RedisStore = struct {
    connection: *RedisConnection,
    ...
};
```

### 8.2 Configuration for Redis (Future)

```yaml
# Future configuration
session:
  store: redis           # "memory" (default) or "redis"
  redis:
    host: localhost
    port: 6379
    password: ""
    database: 0
    prefix: "zhttpd:session:"
```

---

## 9. Implementation Plan

### Phase 1: Core Infrastructure (This PR)
1. Add cache.zig dependency
2. Implement SessionValue type
3. Implement Session and SessionManager
4. Add basic Lua session API
5. Unit tests

### Phase 2: Database Pool Integration
1. Refactor DbManager to use cache-based connection pool
2. Add connection metrics
3. Idle connection cleanup

### Phase 3: Enhanced Features
1. Session ID cookie handling
2. Session middleware
3. Object cache for Lua scripts

### Phase 4: Redis Backend (Future)
1. Redis store implementation
2. Configuration options
3. Fallback handling

---

## 10. File Structure

```
src/
├── cache/
│   ├── file_cache.zig       # Existing file cache
│   ├── object_cache.zig     # New: General object cache
│   └── session.zig          # New: Session types and manager
├── session/
│   ├── session.zig          # Session management
│   ├── value.zig            # SessionValue type
│   └── lua_bindings.zig     # Lua session API
├── plugins/
│   └── db/
│       ├── db.zig           # Existing
│       ├── manager.zig      # Existing
│       └── pool.zig         # New: Cache-based connection pool
└── config/
    └── config.zig           # Add session/cache config
```

---

## 11. API Summary

### Zig API
```zig
// Session management
const session_mgr = try SessionManager.init(allocator, config);
const session = try session_mgr.getOrCreate("session_id");
try session.set("key", .{ .string = "value" });
const value = session.get("key");
session_mgr.delete("session_id");

// Object cache
var obj_cache = try cache.Cache(MyType).init(allocator, .{});
try obj_cache.put("key", value, .{ .ttl = 300 });
if (obj_cache.get("key")) |entry| {
    defer entry.release();
    use(entry.value);
}
```

### Lua API
```lua
-- Session API
local session = context:session()
session:set("user_id", 123)
local user_id = session:get("user_id")
session:delete("temp")
session:clear()
session:destroy()
```

---

## 12. Security Considerations

1. **Session ID Security**
   - Use cryptographically secure random session IDs
   - Session ID length >= 128 bits (32 hex chars)
   
2. **Cookie Security**
   - HttpOnly flag to prevent XSS
   - Secure flag for HTTPS-only
   - SameSite=Lax to prevent CSRF
   
3. **Session Hijacking Prevention**
   - Rotate session ID on privilege change
   - Validate session against IP (optional)
   
4. **Memory Protection**
   - Clear sensitive data on session destroy
   - Limit session data size

---

## Conclusion

This design provides a flexible, thread-safe session management system built on cache.zig. The architecture supports:

- **Immediate needs**: In-memory session caching with Lua interoperability
- **Current infrastructure**: Database connection pool optimization
- **Future extensibility**: Redis backend without architectural changes

The SessionValue type provides multi-type support similar to YAML Value while being optimized for runtime session usage with proper cache integration.
