//! Shared `x-www-form-urlencoded` codec for `Query` (URL) and `Form` (body):
//! the two grammars are identical. Returns neutral `MissingField`/`InvalidField`
//! errors so each caller can remap them to its own contract-specific names.

const std = @import("std");
const scalar = @import("../scalar.zig");

pub const Error = error{ MissingField, InvalidField, OutOfMemory };

/// Decodes `raw` into `T`'s fields by name. Fields with a default are
/// optional; optional types decode to null when absent; anything else is
/// required. The error set is declared (not inferred) so callers can
/// `switch` on it even when a given `T` makes the `MissingField` branch
/// comptime-unreachable.
pub fn parse(comptime T: type, arena: std.mem.Allocator, raw: []const u8) Error!T {
    const fields = @typeInfo(T).@"struct".fields;
    var value: T = undefined;
    var seen = [_]bool{false} ** fields.len;

    var it = std.mem.splitScalar(u8, raw, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const raw_key = if (eq) |i| pair[0..i] else pair;
        const raw_val = if (eq) |i| pair[i + 1 ..] else "";
        const key = try decode(arena, raw_key);
        const val = try decode(arena, raw_val);
        inline for (fields, 0..) |f, fi| {
            if (std.mem.eql(u8, f.name, key)) {
                @field(value, f.name) = scalar.parseScalar(f.type, val) catch
                    return error.InvalidField;
                seen[fi] = true;
            }
        }
        // Unknown keys are ignored: forward-compatible contracts.
    }

    inline for (fields, 0..) |f, fi| {
        if (!seen[fi]) {
            if (f.defaultValue()) |d| {
                @field(value, f.name) = d;
            } else if (@typeInfo(f.type) == .optional) {
                @field(value, f.name) = null;
            } else {
                return error.MissingField;
            }
        }
    }
    return value;
}

/// Percent-decoding plus '+' → space. Borrows `raw` when no decoding is
/// needed (the common case); otherwise copies into the arena.
fn decode(arena: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    if (std.mem.indexOfAny(u8, raw, "%+") == null) return raw;
    var out = try arena.alloc(u8, raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        switch (raw[i]) {
            '+' => out[n] = ' ',
            '%' => {
                if (i + 2 >= raw.len) return error.InvalidField;
                out[n] = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch
                    return error.InvalidField;
                i += 2;
            },
            else => out[n] = raw[i],
        }
        n += 1;
    }
    return out[0..n];
}

// ── Tests ────────────────────────────────────────────────────────────────

test "parse: types, defaults, optionals, required" {
    const P = struct {
        page: u32 = 1,
        per_page: u32 = 20,
        q: ?[]const u8,
        strict: bool = false,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p1 = try parse(P, arena, "page=3&q=zig%20web&strict=true");
    try std.testing.expectEqual(3, p1.page);
    try std.testing.expectEqual(20, p1.per_page);
    try std.testing.expectEqualStrings("zig web", p1.q.?);
    try std.testing.expectEqual(true, p1.strict);

    const p2 = try parse(P, arena, "");
    try std.testing.expectEqual(1, p2.page);
    try std.testing.expectEqual(null, p2.q);

    const R = struct { id: u64 };
    try std.testing.expectError(error.MissingField, parse(R, arena, ""));
    try std.testing.expectError(error.InvalidField, parse(R, arena, "id=abc"));
}

test "decode: borrow fast path and decode path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = "hello";
    const decoded_plain = try decode(arena, plain);
    try std.testing.expectEqual(plain.ptr, decoded_plain.ptr); // borrowed

    try std.testing.expectEqualStrings("a b+c", try decode(arena, "a+b%2Bc"));
    try std.testing.expectError(error.InvalidField, decode(arena, "%2"));
    try std.testing.expectError(error.InvalidField, decode(arena, "%zz"));
}
