//! Shared plumbing for the body extractors (Json/Form/Bytes/Multipart):
//! whole-body collection into the request arena, and media-type matching.

const std = @import("std");

/// Failure modes shared by every body extractor; folded into the
/// framework-wide `wing.extract.Error` aggregate.
pub const Error = error{
    /// The request's Content-Type does not match what the body extractor
    /// requires (`Json`: application/json, `Form`: x-www-form-urlencoded,
    /// `Multipart`: multipart/form-data). Maps to 415.
    UnsupportedMediaType,
    /// A streamed body exceeded the server's `max_body_size` (413). Only
    /// chunked bodies reach this — oversized Content-Length bodies are
    /// rejected by talon before the handler runs.
    PayloadTooLarge,
};

/// Collects the whole request body into the request arena — the shared
/// front half of every body extractor. A failed stream is classified: a
/// size-limit breach becomes `PayloadTooLarge`; every other failure is the
/// neutral `BodyReadFailed`, which each caller remaps to its own
/// contract-specific 400 error.
pub fn collect(ctx: anytype) error{ PayloadTooLarge, BodyReadFailed }![]const u8 {
    var collected: std.Io.Writer.Allocating = .init(ctx.arena);
    _ = ctx.req.bodyReader().streamRemaining(&collected.writer) catch {
        if (ctx.req.bodyError()) |berr| {
            if (berr == error.BodyTooLarge) return error.PayloadTooLarge;
        }
        return error.BodyReadFailed;
    };
    return collected.written();
}

/// The media type of a Content-Type value: parameters (`; charset=...`)
/// stripped, surrounding whitespace trimmed. Comparisons on the result must
/// stay case-insensitive — media types are case-insensitive (RFC 9110).
pub fn mediaTypeOf(value: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.mem.trim(u8, value[0..end], " \t");
}
