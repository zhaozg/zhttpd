# JSON Library Evaluation: zimdjson vs std.json

This document evaluates [zimdjson](https://github.com/EzequielRamis/zimdjson) for potential integration into zhttpd as a replacement for the current `std.json` based implementation.

## Executive Summary

**Decision: Do NOT integrate zimdjson at this time.**

While zimdjson offers impressive performance characteristics, several critical issues make it unsuitable for zhttpd:

1. **Zig Version Incompatibility**: zimdjson requires Zig 0.14.x, but zhttpd requires Zig 0.15.x
2. **Platform Restrictions**: SIMD-only design limits portability
3. **Limited Encoding Support**: zimdjson is parsing-only, no JSON serialization
4. **Complexity Mismatch**: zhttpd's JSON needs are simple and well-served by std.json

## Detailed Analysis

### 1. Compatibility Issues

#### Zig Version Incompatibility (Critical)

zimdjson v0.1.1 specifies `minimum_zig_version = "0.14.0"` and uses the 0.14.x build API:

```zig
// zimdjson build.zig (0.14.x syntax)
.root_source_file = b.path("tests/adversarial_gen.zig"),

// Zig 0.15.x requires:
.root_module = b.createModule(.{
    .root_source_file = b.path("tests/adversarial_gen.zig"),
    // ...
}),
```

This is a **breaking API change** between Zig 0.14 and 0.15. zhttpd requires Zig 0.15.x per its build requirements.

#### SIMD Requirements (Moderate)

zimdjson requires SIMD vector instructions:

```zig
// From types.zig
pub const bytes_len = simd.suggestVectorLength(u8) orelse @compileError("No SIMD features available");
```

Some intrinsics only support x86_64 and aarch64:

```zig
// From intrinsics.zig
pub inline fn lookupTable(table: vector, nibbles: vector) vector {
    switch (cpu.arch) {
        .x86_64 => { /* AVX2/SSSE3 intrinsics */ },
        .aarch64 => { /* NEON intrinsics */ },
        else => @compileError("Intrinsic not implemented for this target"),
    }
}
```

This limits portability to platforms without SIMD support.

### 2. Feature Gap Analysis

#### No JSON Serialization

zimdjson is a **parsing-only** library. zhttpd requires JSON serialization for:

- Lua `cjson.encode()` function
- GraphQL response generation
- Error response formatting
- Metric/health endpoint JSON output

The current implementation uses `std.json.parseFromSlice()` for parsing and custom serialization in `src/lua/json.zig`. Replacing only parsing would provide minimal benefit while adding a dependency.

#### Current zhttpd JSON Usage

| Module | Operation | Current Implementation |
|--------|-----------|------------------------|
| `src/lua/json.zig` | Decode | `std.json.parseFromSlice()` |
| `src/lua/json.zig` | Encode | Custom `luaValueToJson()` |
| `src/graphql/graphql.zig` | Response | Custom JSON building |
| `src/handlers/*.zig` | Parse/Response | `std.json` + string literals |
| `src/config/config.zig` | Parse | YAML library (not JSON) |

### 3. Performance Context

#### zimdjson Performance Claims

According to zimdjson benchmarks:
- Parsing speed: 2-5 GB/s on modern x86_64 CPUs
- SIMD-accelerated structural character detection
- On-demand parsing with O(1) memory for streaming

#### zhttpd Performance Reality

zhttpd's JSON operations are not a performance bottleneck:

1. **Request bodies are small**: Typical API requests are < 1KB
2. **Caching reduces parsing**: File cache minimizes repeated operations
3. **Lua is the bottleneck**: Script execution dominates API response time
4. **Static files dominate**: Most traffic serves cached static content

Current benchmark results show:
- **~46,000 req/s** with h2load (static files)
- **~10,500 req/s** with Apache Bench

JSON parsing is a negligible portion of request handling time.

### 4. Implementation Complexity

#### Current Implementation Advantages

The current `std.json` based implementation:

1. **Zero dependencies**: Uses only Zig standard library
2. **Full control**: Custom serialization handles Lua types correctly
3. **Well tested**: Existing test coverage for edge cases
4. **Simple maintenance**: Single file (`src/lua/json.zig`)

#### zimdjson Integration Challenges

Integrating zimdjson would require:

1. Forking and maintaining a zimdjson port to Zig 0.15.x
2. Adding new serialization code (zimdjson is parse-only)
3. Adapting the on-demand API to work with Lua value conversion
4. Adding complexity to handle streaming mode vs full parsing

### 5. Alternative Consideration

If JSON parsing performance becomes a bottleneck in the future:

1. **Wait for zimdjson 0.15.x support**: The maintainer may update the library
2. **Profile first**: Identify if JSON is actually the bottleneck
3. **Use std.json optimizations**: Arena allocators, streaming parsing
4. **LuaJIT for Lua side**: Already supported, provides faster script execution

## Conclusion

zimdjson is an excellent high-performance JSON parsing library, but it is **not suitable for zhttpd** because:

1. **Version Incompatibility**: Cannot build with Zig 0.15.x (required by zhttpd)
2. **Missing Features**: No JSON serialization (required for responses)
3. **Platform Limitations**: SIMD-only design reduces portability
4. **Minimal Benefit**: JSON parsing is not a bottleneck in zhttpd

The current `std.json` based implementation is adequate for zhttpd's needs and provides:
- Full encode/decode support
- Cross-platform compatibility
- Zero external dependencies
- Simple maintenance

## Recommendation

**Keep the current std.json implementation.** Re-evaluate zimdjson when:

1. zimdjson adds Zig 0.15.x support
2. JSON parsing is identified as a performance bottleneck
3. JSON serialization is added to zimdjson

---

*Evaluation Date: November 2024*
*Zig Version Tested: 0.15.2*
*zimdjson Version Tested: 0.1.1*
