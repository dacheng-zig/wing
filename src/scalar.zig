//! Scalar field parsing shared by the struct-binding extractors
//! (Query/Path/Headers/Cookies). One decode rule for every typed binder so
//! they stay consistent: integers, floats, bool, enums, `[]const u8`,
//! optionals thereof — plus any struct declaring the `fromScalar` convention.
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
        // Decode convention for value types that travel as text (uuids,
        // ulids, …): `pub fn fromScalar(raw: []const u8) !T`. The error is
        // mapped by each binder to its contract error (Invalid*Param).
        .@"struct" => if (comptime std.meta.hasFn(T, "fromScalar"))
            T.fromScalar(raw)
        else
            unsupportedScalar(T),
        else => unsupportedScalar(T),
    };
}

pub fn unsupportedScalar(comptime T: type) noreturn {
    @compileError("wing: unsupported Query/Path/Headers/Cookies field type " ++ @typeName(T) ++
        " — supported: integers, floats, bool, enums, []const u8, optionals thereof, " ++
        "and structs declaring `pub fn fromScalar(raw: []const u8) !T`");
}

test "parseScalar: enums and optionals" {
    const Color = enum { red, green };
    try std.testing.expectEqual(Color.red, try parseScalar(Color, "red"));
    try std.testing.expectError(error.InvalidCharacter, parseScalar(Color, "blue"));
    try std.testing.expectEqual(@as(?u32, 7), try parseScalar(?u32, "7"));
    try std.testing.expectEqual(true, try parseScalar(bool, "1"));
}

test "parseScalar: fromScalar convention on structs" {
    const Wrapped = struct {
        n: u32,
        pub fn fromScalar(raw: []const u8) !@This() {
            return .{ .n = try std.fmt.parseInt(u32, raw, 10) };
        }
    };
    try std.testing.expectEqual(@as(u32, 7), (try parseScalar(Wrapped, "7")).n);
    try std.testing.expectEqual(@as(u32, 7), (try parseScalar(?Wrapped, "7")).?.n);
    try std.testing.expectError(error.InvalidCharacter, parseScalar(Wrapped, "x"));
}
