//! Request-header extractor.

const std = @import("std");
const scalar = @import("../scalar.zig");

/// Folded into the framework-wide `wing.extract.Error` aggregate.
pub const Error = error{ MissingHeader, InvalidHeader };

/// Binds request headers to `T`'s fields by name (fromRequestParts). Field
/// names map to header names with `_` → `-` (`user_agent` → `user-agent`;
/// header lookup is case-insensitive). Field types and required/optional
/// rules match Query; string fields borrow the header buffer (zero-copy).
/// When a header is repeated, the first occurrence wins (like `CookieView`).
pub fn Headers(comptime T: type) type {
    return struct {
        value: T,

        pub fn fromRequestParts(ctx: anytype) !@This() {
            var value: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                if (ctx.req.header(comptime headerName(f.name))) |raw| {
                    @field(value, f.name) = scalar.parseScalar(f.type, raw) catch
                        return error.InvalidHeader;
                } else if (f.defaultValue()) |d| {
                    @field(value, f.name) = d;
                } else if (@typeInfo(f.type) == .optional) {
                    @field(value, f.name) = null;
                } else {
                    return error.MissingHeader;
                }
            }
            return .{ .value = value };
        }
    };
}

/// The header name a `Headers` field binds to: `_` → `-`, so identifiers can
/// express the hyphenated wire names.
fn headerName(comptime field: []const u8) []const u8 {
    comptime {
        var buf: [field.len]u8 = undefined;
        for (field, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
        const out = buf;
        return &out;
    }
}

test "headerName: underscores become hyphens" {
    try std.testing.expectEqualStrings("user-agent", comptime headerName("user_agent"));
    try std.testing.expectEqualStrings("x-request-id", comptime headerName("x_request_id"));
    try std.testing.expectEqualStrings("host", comptime headerName("host"));
}
