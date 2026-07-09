//! Raw-body extractor.

const body_mod = @import("body.zig");

/// Folded into the framework-wide `wing.extract.Error` aggregate.
pub const Error = error{
    /// The raw body stream could not be read.
    InvalidBody,
};

/// The raw request body, collected into the request arena (fromRequest).
/// For handlers that do their own parsing or proxying. Size is bounded by
/// the server's `max_body_size` (oversized → 413, like Json/Form).
pub const Bytes = struct {
    value: []const u8,

    pub fn fromRequest(ctx: anytype) !Bytes {
        const body = body_mod.collect(ctx) catch |e| return switch (e) {
            error.BodyReadFailed => error.InvalidBody,
            error.PayloadTooLarge => error.PayloadTooLarge,
        };
        return .{ .value = body };
    }
};
