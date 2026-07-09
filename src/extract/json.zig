//! JSON body extractor. The response-side counterpart is
//! `wing.respond.Json` — same name, opposite direction.

const std = @import("std");
const body_mod = @import("body.zig");

/// Folded into the framework-wide `wing.extract.Error` aggregate.
pub const Error = error{InvalidJsonBody};

/// Consumes and parses an `application/json` request body into `T`
/// (fromRequest). Wrong or missing Content-Type → 415; parse failure → 400.
pub fn Json(comptime T: type) type {
    return struct {
        value: T,

        pub fn fromRequest(ctx: anytype) !@This() {
            const ct = ctx.req.header("content-type") orelse
                return error.UnsupportedMediaType;
            if (!isJsonContentType(ct)) return error.UnsupportedMediaType;

            const body = body_mod.collect(ctx) catch |e| return switch (e) {
                error.BodyReadFailed => error.InvalidJsonBody,
                error.PayloadTooLarge => error.PayloadTooLarge,
            };
            const value = std.json.parseFromSliceLeaky(
                T,
                ctx.arena,
                body,
                .{ .allocate = .alloc_always },
            ) catch return error.InvalidJsonBody;
            return .{ .value = value };
        }
    };
}

/// application/json plus the RFC 6839 structured-syntax suffix family
/// (application/*+json, e.g. application/problem+json).
fn isJsonContentType(value: []const u8) bool {
    const mt = body_mod.mediaTypeOf(value);
    if (std.ascii.eqlIgnoreCase(mt, "application/json")) return true;
    // The subtype base must be non-empty: "application/+json" is not a type.
    return mt.len > "application/".len + "+json".len and
        std.ascii.startsWithIgnoreCase(mt, "application/") and
        std.ascii.endsWithIgnoreCase(mt, "+json");
}

test "isJsonContentType: application/json and +json suffix" {
    try std.testing.expect(isJsonContentType("application/json"));
    try std.testing.expect(isJsonContentType("application/json; charset=utf-8"));
    try std.testing.expect(isJsonContentType("Application/JSON"));
    try std.testing.expect(isJsonContentType("application/problem+json"));
    try std.testing.expect(isJsonContentType("application/vnd.api+JSON"));
    try std.testing.expect(!isJsonContentType("text/json")); // not a registered json type
    try std.testing.expect(!isJsonContentType("application/jsonp"));
    try std.testing.expect(!isJsonContentType("application/+json")); // empty subtype base
    try std.testing.expect(!isJsonContentType("text/plain"));
    try std.testing.expect(!isJsonContentType(""));
}
