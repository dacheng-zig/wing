//! Form-urlencoded body extractor.

const std = @import("std");
const body_mod = @import("body.zig");
const urlencoded = @import("urlencoded.zig");

/// Folded into the framework-wide `wing.extract.Error` aggregate.
pub const Error = error{
    /// The form body stream could not be read.
    InvalidFormBody,
    MissingFormField,
    InvalidFormField,
};

/// Parses an `application/x-www-form-urlencoded` request body into `T`
/// (fromRequest). The body grammar matches the query string, so it shares
/// `Query`'s codec — only the source (body vs URL) and the strict
/// Content-Type guard differ. Field-type and required/optional rules are
/// identical to `Query`. For `multipart/form-data`, use `Multipart`.
pub fn Form(comptime T: type) type {
    return struct {
        value: T,

        pub fn fromRequest(ctx: anytype) !@This() {
            const ct = ctx.req.header("content-type") orelse
                return error.UnsupportedMediaType;
            if (!isFormContentType(ct)) return error.UnsupportedMediaType;

            const body = body_mod.collect(ctx) catch |e| return switch (e) {
                error.BodyReadFailed => error.InvalidFormBody,
                error.PayloadTooLarge => error.PayloadTooLarge,
            };
            return .{
                .value = urlencoded.parse(T, ctx.arena, body) catch |e| switch (e) {
                    error.MissingField => return error.MissingFormField,
                    error.InvalidField => return error.InvalidFormField,
                    else => |other| return other, // OutOfMemory
                },
            };
        }
    };
}

fn isFormContentType(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(
        body_mod.mediaTypeOf(value),
        "application/x-www-form-urlencoded",
    );
}

test "isFormContentType: media type match ignores params and case" {
    try std.testing.expect(isFormContentType("application/x-www-form-urlencoded"));
    try std.testing.expect(isFormContentType("application/x-www-form-urlencoded; charset=utf-8"));
    try std.testing.expect(isFormContentType("Application/X-WWW-Form-Urlencoded"));
    try std.testing.expect(isFormContentType("  application/x-www-form-urlencoded  "));
    try std.testing.expect(!isFormContentType("application/json"));
    try std.testing.expect(!isFormContentType("multipart/form-data; boundary=x"));
    try std.testing.expect(!isFormContentType(""));
}
