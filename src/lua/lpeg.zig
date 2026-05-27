//! LPeg (Lua Parsing Expression Grammar) module for Lua integration
//!
//! This module integrates LPeg (http://www.inf.puc-rio.br/~roberto/lpeg/)
//! for powerful pattern matching and parsing in Lua. LPeg is based on
//! Parsing Expression Grammars (PEGs) and provides a first-class pattern
//! matching facility.
//!
//! The module exposes the complete LPeg API:
//! - lpeg.P(pattern) - Create a pattern
//! - lpeg.R(range) - Create a range pattern
//! - lpeg.S(set) - Create a set pattern
//! - lpeg.V(name) - Create a variable pattern (for grammars)
//! - lpeg.match(pattern, subject) - Match a pattern against a string
//! - And many more pattern operations and captures
//!
//! LPeg is particularly useful for:
//! - Complex string parsing and validation
//! - Building lexers and parsers
//! - Pattern matching beyond regular expressions
//! - Grammar-based text processing

const std = @import("std");
const ziglua = @import("ziglua");

// Import the C luaopen_lpeg function from lpeg library
// This is linked from vendor/lpeg compiled with zig build
extern fn luaopen_lpeg(L: ?*ziglua.LuaState) c_int;

/// Register the lpeg module
/// This provides powerful pattern matching capabilities based on PEGs
/// The allocator parameter is kept for API compatibility.
pub fn registerLpegModule(lua: *ziglua.Lua, getAllocator: *const fn () std.mem.Allocator) !void {
    // Store the allocator getter for API consistency
    _ = getAllocator;

    _ = lua.getGlobal("package");
    _ = lua.getField(-1, "preload");
    lua.pushFunction(luaopen_lpeg);
    _ = lua.setField(-2, "lpeg");
    lua.pop(2); // pop package and preload
}
