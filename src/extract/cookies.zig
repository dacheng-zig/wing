//! Typed cookie extractor. The `Cookie` value type, `View` reader, and
//! Set-Cookie serialization live in the cookie component (`src/cookie.zig`);
//! this file only binds request cookies into handler parameters.

const std = @import("std");
const scalar = @import("../scalar.zig");
const cookie_mod = @import("../cookie.zig");

/// Folded into the framework-wide `wing.extract.Error` aggregate.
pub const Error = error{
    /// A required cookie is absent.
    MissingCookie,
    /// A cookie is present but unparsable as the field's type.
    InvalidCookie,
};

/// Binds request cookies into the fields of `T` by field name
/// (fromRequestParts), mirroring `Query(T)`/`Path(T)`. Field types:
/// integers, floats, bool, enums, `[]const u8`, optionals thereof. Fields
/// with a default or an optional type are optional in the request; others
/// raise `error.MissingCookie`. Cookie values are opaque bytes — they are
/// bound verbatim, not percent-decoded.
pub fn Cookies(comptime T: type) type {
    return struct {
        value: T,

        pub fn fromRequestParts(ctx: anytype) !@This() {
            const view = cookie_mod.View.init(ctx.req.header("cookie") orelse "");
            var value: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                if (view.get(f.name)) |raw| {
                    @field(value, f.name) = scalar.parseScalar(f.type, raw) catch
                        return error.InvalidCookie;
                } else if (f.defaultValue()) |d| {
                    @field(value, f.name) = d;
                } else if (@typeInfo(f.type) == .optional) {
                    @field(value, f.name) = null;
                } else {
                    return error.MissingCookie;
                }
            }
            return .{ .value = value };
        }
    };
}
