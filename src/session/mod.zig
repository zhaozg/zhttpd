//! Session Management Module
//!
//! This module provides session management for zhttpd.
//! It uses cache.zig for thread-safe, LRU-based session storage.
//!
//! ## Features
//! - Thread-safe session storage
//! - Configurable max sessions and TTL
//! - Automatic session cleanup on expiration
//! - Lua bindings for session access
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────┐     ┌──────────────────┐
//! │  Lua Script     │────▶│  Lua Bindings    │
//! │  context:session()    │  (lua_bindings)   │
//! └─────────────────┘     └────────┬─────────┘
//!                                  │
//!                                  ▼
//!                         ┌──────────────────┐
//!                         │ SessionManager   │
//!                         │ (session.zig)    │
//!                         └────────┬─────────┘
//!                                  │
//!                                  ▼
//!                         ┌──────────────────┐
//!                         │ cache.zig        │
//!                         │ (Thread-safe LRU)│
//!                         └──────────────────┘
//! ```
//!
//! ## Usage
//!
//! ### Zig API
//! ```zig
//! const session = @import("session");
//!
//! var manager = try session.SessionManager.init(allocator, .{});
//! defer manager.deinit();
//!
//! const id = try manager.create();
//! try manager.set(&id, "user_id", session.SessionValue.initInt(123));
//! ```
//!
//! ### Lua API
//! ```lua
//! function handle(request, response, context)
//!     local session = context:session()
//!     session:set("user_id", 123)
//!     local uid = session:get("user_id")
//!     return { user_id = uid }
//! end
//! ```

pub const value = @import("value.zig");
pub const session = @import("session.zig");
pub const lua_bindings = @import("lua_bindings.zig");

// Re-export main types
pub const SessionValue = value.SessionValue;
pub const Session = session.Session;
pub const SessionManager = session.SessionManager;
pub const SessionConfig = session.SessionConfig;

// Re-export constants
pub const DEFAULT_SESSION_TTL = session.DEFAULT_SESSION_TTL;
pub const DEFAULT_MAX_SESSIONS = session.DEFAULT_MAX_SESSIONS;
pub const SESSION_ID_HEX_LEN = session.SESSION_ID_HEX_LEN;

// Re-export global manager functions
pub const setGlobalManager = session.setGlobalManager;
pub const getGlobalManager = session.getGlobalManager;

// Re-export Lua binding functions
pub const registerSessionMetatable = lua_bindings.registerSessionMetatable;
pub const pushSession = lua_bindings.pushSession;
pub const setCurrentSession = lua_bindings.setCurrentSession;
pub const getCurrentSession = lua_bindings.getCurrentSession;
pub const clearCurrentSession = lua_bindings.clearCurrentSession;

test {
    // Run all tests in submodules
    _ = @import("value.zig");
    _ = @import("session.zig");
    _ = @import("lua_bindings.zig");
}
