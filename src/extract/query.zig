//! Query-string extractor.

const std = @import("std");
const urlencoded = @import("urlencoded.zig");

/// Folded into the framework-wide `wing.extract.Error` aggregate.
pub const Error = error{ MissingQueryParam, InvalidQueryParam };

/// Decodes the query string into `T` (fromRequestParts). Field types:
/// integers, floats, bool, enums, `[]const u8`, optionals thereof. Fields
/// with defaults are optional in the URL; others are required.
pub fn Query(comptime T: type) type {
    return struct {
        value: T,

        pub fn fromRequestParts(ctx: anytype) !@This() {
            const target = ctx.req.target();
            const raw = if (std.mem.indexOfScalar(u8, target, '?')) |i|
                target[i + 1 ..]
            else
                "";
            return .{
                .value = urlencoded.parse(T, ctx.arena, raw) catch |e| switch (e) {
                    error.MissingField => return error.MissingQueryParam,
                    error.InvalidField => return error.InvalidQueryParam,
                    else => |other| return other, // OutOfMemory
                },
            };
        }
    };
}
