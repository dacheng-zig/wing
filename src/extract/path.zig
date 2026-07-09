//! Path-parameter extractor.

const std = @import("std");
const scalar = @import("../scalar.zig");

/// Folded into the framework-wide `wing.extract.Error` aggregate.
pub const Error = error{ MissingPathParam, InvalidPathParam };

/// Binds path parameters captured by the router to `T`'s fields by name
/// (fromRequestParts). Same field-type support as Query.
pub fn Path(comptime T: type) type {
    return struct {
        value: T,

        pub fn fromRequestParts(ctx: anytype) !@This() {
            var value: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                const raw = ctx.params.get(f.name) orelse
                    return error.MissingPathParam;
                @field(value, f.name) = scalar.parseScalar(f.type, raw) catch
                    return error.InvalidPathParam;
            }
            return .{ .value = value };
        }
    };
}
