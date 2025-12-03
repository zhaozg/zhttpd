# Database Plugin API Reference

## Overview

The database plugin provides a unified interface for database operations through the `zdbc` library. It supports SQLite, PostgreSQL, and MySQL with prepared statement caching for optimal performance.

## Key Concepts

### Direct vs. Cached Queries

The refactored API provides clear separation between direct database calls and cached prepared statements:

- **Direct queries**: Use `db.query()` and `db.exec()` for one-time or infrequent operations
- **Cached statements**: Use `db.prepare()` for frequently executed queries to benefit from automatic caching

### Statement Caching

When you call `db.prepare(sql)`, the plugin:
1. Checks if the statement is already cached
2. If cached (cache hit), returns the existing prepared statement
3. If not cached (cache miss), prepares the statement and adds it to the cache
4. Automatically evicts old statements when cache is full (FIFO-like eviction)

Benefits of caching:
- Reduced SQL parsing overhead
- Better performance for repeated queries
- Automatic management (no manual cleanup needed)

## Lua API

### db.query(sql, ...)

Execute a SELECT query directly without statement caching.

**Parameters:**
- `sql` (string): SQL query with optional `?` placeholders
- `...` (varargs): Parameter values to bind (supports: numbers, strings, booleans, nil)

**Returns:**
- On success: Table of result rows, each row is a table with column names as keys
- On error: `nil, error_message`

**Example:**
```lua
-- Simple query
local users, err = db.query("SELECT * FROM users")
if err then
    print("Error:", err)
    return
end

for _, user in ipairs(users) do
    print(user.id, user.name, user.email)
end

-- Query with parameters
local user, err = db.query("SELECT * FROM users WHERE id = ?", 42)
if err then
    print("Error:", err)
else
    print("Found:", user[1].name)
end
```

**When to use:**
- One-time queries (e.g., schema creation, migrations)
- Infrequently executed queries
- Dynamic queries where SQL varies significantly

### db.exec(sql, ...)

Execute an INSERT, UPDATE, DELETE, or DDL statement directly without statement caching.

**Parameters:**
- `sql` (string): SQL statement with optional `?` placeholders
- `...` (varargs): Parameter values to bind

**Returns:**
- On success: Number of affected rows
- On error: `nil, error_message`

**Example:**
```lua
-- Insert
local affected, err = db.exec("INSERT INTO users (name, email) VALUES (?, ?)", "Alice", "alice@example.com")
if err then
    print("Insert failed:", err)
else
    print("Inserted", affected, "row(s)")
end

-- Update
local affected, err = db.exec("UPDATE users SET active = ? WHERE id = ?", 1, 42)

-- Delete
local affected, err = db.exec("DELETE FROM users WHERE id = ?", 42)
```

**When to use:**
- One-time operations (schema creation, bulk updates)
- Infrequently executed statements
- Administrative operations

### db.prepare(sql)

Prepare a statement with automatic caching for repeated execution.

**Parameters:**
- `sql` (string): SQL statement with optional `?` placeholders

**Returns:**
- On success: Statement object with `query()` and `exec()` methods
- On error: `nil, error_message`

**Statement Object Methods:**

#### statement:query(...)

Execute the prepared statement as a query (SELECT).

**Parameters:**
- `...` (varargs): Parameter values to bind

**Returns:**
- Same as `db.query()` - table of result rows or `nil, error_message`

#### statement:exec(...)

Execute the prepared statement as a command (INSERT, UPDATE, DELETE).

**Parameters:**
- `...` (varargs): Parameter values to bind

**Returns:**
- Same as `db.exec()` - number of affected rows or `nil, error_message`

**Example:**
```lua
-- Prepare once, execute many times
local insert_stmt = db.prepare("INSERT INTO users (name, email) VALUES (?, ?)")

-- First execution (cache miss)
local affected1, err1 = insert_stmt:exec("Alice", "alice@example.com")
-- Second execution (cache hit - reuses prepared statement)
local affected2, err2 = insert_stmt:exec("Bob", "bob@example.com")
-- Third execution (cache hit)
local affected3, err3 = insert_stmt:exec("Carol", "carol@example.com")

-- Query example
local select_stmt = db.prepare("SELECT * FROM users WHERE id = ?")
local user1, err1 = select_stmt:query(1)  -- Cache miss
local user2, err2 = select_stmt:query(2)  -- Cache hit
local user3, err3 = select_stmt:query(3)  -- Cache hit
```

**When to use:**
- Queries executed multiple times in a request
- Batch operations (inserts, updates, deletes)
- Performance-critical code paths
- Frequently accessed data patterns

### db.begin()

Begin a database transaction.

**Returns:**
- `true` on success
- `false, error_message` on error

**Example:**
```lua
local ok, err = db.begin()
if not ok then
    print("Failed to begin transaction:", err)
    return
end
```

### db.commit()

Commit the current transaction.

**Returns:**
- `true` on success
- `false, error_message` on error

**Example:**
```lua
local ok, err = db.commit()
if not ok then
    print("Failed to commit:", err)
    return
end
```

### db.rollback()

Rollback the current transaction.

**Returns:**
- `true` on success
- `false, error_message` on error

**Example:**
```lua
local ok, err = db.rollback()
if not ok then
    print("Failed to rollback:", err)
end
```

### Transaction Example

```lua
-- Safe transaction with error handling
local ok, err = db.begin()
if not ok then
    return nil, "Failed to begin transaction: " .. err
end

-- Perform multiple operations
local affected1, err1 = db.exec("UPDATE accounts SET balance = balance - ? WHERE id = ?", 100, 1)
if err1 then
    db.rollback()
    return nil, "Failed to debit: " .. err1
end

local affected2, err2 = db.exec("UPDATE accounts SET balance = balance + ? WHERE id = ?", 100, 2)
if err2 then
    db.rollback()
    return nil, "Failed to credit: " .. err2
end

-- Commit transaction
ok, err = db.commit()
if not ok then
    return nil, "Failed to commit: " .. err
end

return { status = "success", message = "Transfer completed" }
```

### db.status()

Get database connection status and cache statistics.

**Returns:**
- Table with status information

**Example:**
```lua
local status = db.status()

print("Connected:", status.connected)
print("Database URI:", status.uri)
print("Pool size:", status.pool_size)
print("Statement cache size:", status.stmt_cache_size)

-- Cache statistics
if status.stmt_cache_stats then
    local stats = status.stmt_cache_stats
    print("Cache hits:", stats.hits)
    print("Cache misses:", stats.misses)
    print("Hit rate:", stats.hit_rate)
    print("Cached statements:", stats.size)
    print("Max cache size:", stats.max_size)
end
```

## Zig API

### DbPlugin Methods

The following methods are available when using DbPlugin directly from Zig:

#### query(self, sql, params) !Result

Execute a query directly without caching.

#### exec(self, sql, params) !usize

Execute a statement directly without caching.

#### prepare(self, sql) !*Statement

Prepare a statement with caching. Returns a pointer to the cached statement.

#### begin(self) !void

Begin a transaction.

#### commit(self) !void

Commit the current transaction.

#### rollback(self) !void

Rollback the current transaction.

#### lastInsertId(self) ?i64

Get the last inserted row ID (database-specific).

#### affectedRows(self) usize

Get the number of rows affected by the last operation.

#### ping(self) !void

Ping the database to check connection health.

#### lastError(self) ?[]const u8

Get the last error message.

### Example Usage in Zig

```zig
const std = @import("std");
const zdbc = @import("zdbc");
const DbPlugin = @import("plugins/db/db.zig").DbPlugin;

pub fn example(plugin: *DbPlugin) !void {
    // Direct query
    var result = try plugin.query("SELECT * FROM users WHERE age > ?", &.{
        zdbc.Value.initInt(18),
    });
    defer result.deinit();

    // Prepared statement with caching
    var stmt = try plugin.prepare("INSERT INTO users (name, age) VALUES (?, ?)");
    try stmt.bindAll(&.{
        zdbc.Value.initText("Alice"),
        zdbc.Value.initInt(30),
    });
    const affected = try stmt.exec();

    // Transaction
    try plugin.begin();
    _ = try plugin.exec("UPDATE accounts SET balance = balance - 100 WHERE id = ?", &.{
        zdbc.Value.initInt(1),
    });
    _ = try plugin.exec("UPDATE accounts SET balance = balance + 100 WHERE id = ?", &.{
        zdbc.Value.initInt(2),
    });
    try plugin.commit();
}
```

## Performance Best Practices

### 1. Use Prepared Statements for Repeated Queries

**Bad:**
```lua
for i = 1, 100 do
    db.query("SELECT * FROM users WHERE id = ?", i)  -- No caching, parses SQL 100 times
end
```

**Good:**
```lua
local stmt = db.prepare("SELECT * FROM users WHERE id = ?")
for i = 1, 100 do
    stmt:query(i)  -- Cached, parses SQL only once
end
```

### 2. Use Direct Queries for One-Time Operations

**Good:**
```lua
-- Schema creation (run once)
db.exec([[
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL
    )
]])
```

### 3. Batch Operations with Prepared Statements

**Good:**
```lua
local stmt = db.prepare("INSERT INTO logs (message, level) VALUES (?, ?)")

db.begin()
for _, log in ipairs(log_batch) do
    stmt:exec(log.message, log.level)
end
db.commit()
```

### 4. Monitor Cache Performance

```lua
local status = db.status()
local stats = status.stmt_cache_stats

-- Aim for high hit rate (> 0.8 for performance-critical apps)
if stats.hit_rate < 0.5 then
    print("Warning: Low cache hit rate:", stats.hit_rate)
    print("Consider using prepare() for frequently executed queries")
end
```

## Configuration

In `zhttpd.yaml`:

```yaml
enable_db: true
db_uri: "sqlite:///data/app.db"
db_pool_size: 10              # Reserved for future pooling
stmt_cache_size: 100          # Maximum cached statements per connection
```

### Cache Size Guidelines

- **Small apps (< 10 queries)**: 10-20 statements
- **Medium apps (10-50 queries)**: 50-100 statements
- **Large apps (> 50 queries)**: 100-200 statements

Monitor cache statistics to adjust the size appropriately.

## Error Handling

All database operations can fail. Always check for errors:

```lua
local result, err = db.query("SELECT * FROM users")
if err then
    -- Handle error
    response:status(500)
    return { status = "error", message = err }
end

-- Use result
for _, user in ipairs(result) do
    print(user.name)
end
```

## Thread Safety

- Each request handler has its own database connection
- Statement caches are scoped per connection (not shared)
- No manual synchronization needed for request handlers

## Migration from Old API

The old API automatically used caching in `query()` and `exec()`. The new API is more explicit:

**Old code (automatic caching):**
```lua
-- This used to cache automatically
local result = db.query("SELECT * FROM users WHERE id = ?", 1)
```

**New code (explicit caching):**
```lua
-- For repeated queries, use prepare()
local stmt = db.prepare("SELECT * FROM users WHERE id = ?")
local result = stmt:query(1)

-- For one-time queries, use query() directly
local result = db.query("SELECT * FROM system_config")
```

**Benefits of the new API:**
- Clearer intent (caching vs. direct)
- Better performance control
- Easier to reason about cache behavior
- Follows zdbc Connection interface standards
