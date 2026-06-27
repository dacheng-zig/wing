//! Scalar field parsing shared by the struct-binding extractors
//! (Query/Path/Cookies). One decode rule for every typed binder so they stay
//! consistent: integers, floats, bool, enums, `[]const u8`, optionals thereof.
//! Operates on an already-decoded string; transport decoding (url, cookie)
//! is the caller's job.

const std = @import("std");

pub fn parseScalar(comptime T: type, raw: []const u8) !T {
    return switch (@typeInfo(T)) {
        .optional => |o| try parseScalar(o.child, raw),
        .int => std.fmt.parseInt(T, raw, 10),
        .float => std.fmt.parseFloat(T, raw),
        .bool => if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1"))
            true
        else if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0"))
            false
        else
            error.InvalidCharacter,
        .@"enum" => std.meta.stringToEnum(T, raw) orelse error.InvalidCharacter,
        .pointer => if (T == []const u8) raw else unsupportedScalar(T),
        else => unsupportedScalar(T),
    };
}

pub fn unsupportedScalar(comptime T: type) noreturn {
    @compileError("wing: unsupported Query/Path/Cookies field type " ++ @typeName(T) ++
        " — supported: integers, floats, bool, enums, []const u8, optionals thereof");
}

test "parseScalar: enums and optionals" {
    const Color = enum { red, green };
    try std.testing.expectEqual(Color.red, try parseScalar(Color, "red"));
    try std.testing.expectError(error.InvalidCharacter, parseScalar(Color, "blue"));
    try std.testing.expectEqual(@as(?u32, 7), try parseScalar(?u32, "7"));
    try std.testing.expectEqual(true, try parseScalar(bool, "1"));
}
