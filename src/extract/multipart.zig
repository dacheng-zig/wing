//! multipart/form-data body extractor (RFC 7578).
//!
//! Buffered, mirroring Json/Form: the whole body is collected into the
//! request arena (bounded by talon's `max_body_size`, oversized → 413) and
//! parts are zero-copy slices into that buffer. A streaming variant needs
//! engine-level support and is deferred, like the timeout middleware.
//!
//! Pragmatic parser limits: backslash escapes inside quoted parameter
//! values are not decoded (browsers percent-encode instead of escaping),
//! and the deprecated content-transfer-encoding part header is ignored.
//! Part data whose first line starts with the dash-boundary is read as an
//! omitted body plus delimiter — that is the RFC 2046 grammar's reading of
//! those bytes; only senders violating §5.1.1 (boundary must not prefix
//! any line of the content) ever produce them.

const std = @import("std");
const body_mod = @import("body.zig");

/// Folded into the framework-wide `wing.extract.Error` aggregate.
pub const Error = error{InvalidMultipartBody};

/// Parses a `multipart/form-data` request body (fromRequest). Wrong media
/// type → 415; missing boundary, malformed framing, or a part without the
/// RFC-required `name` → 400.
pub const Multipart = struct {
    parts: []const Part,

    pub const Part = struct {
        /// The form-field name from Content-Disposition.
        name: []const u8,
        /// Present iff the part is a file upload.
        filename: ?[]const u8 = null,
        /// The part's own Content-Type header, when sent.
        content_type: ?[]const u8 = null,
        /// Raw payload; borrows the collected body in the request arena.
        data: []const u8,
    };

    pub fn fromRequest(ctx: anytype) !Multipart {
        const ct = ctx.req.header("content-type") orelse
            return error.UnsupportedMediaType;
        if (!isMultipartContentType(ct)) return error.UnsupportedMediaType;
        const boundary = boundaryOf(ct) orelse return error.InvalidMultipartBody;
        const body = body_mod.collect(ctx) catch |e| return switch (e) {
            error.BodyReadFailed => error.InvalidMultipartBody,
            error.PayloadTooLarge => error.PayloadTooLarge,
        };
        return .{ .parts = try parse(ctx.arena, body, boundary) };
    }

    /// First non-file part with this name, or null. For text form fields.
    pub fn field(self: Multipart, name: []const u8) ?[]const u8 {
        for (self.parts) |p| {
            if (p.filename == null and std.mem.eql(u8, p.name, name)) return p.data;
        }
        return null;
    }

    /// First file part with this name, or null.
    pub fn file(self: Multipart, name: []const u8) ?Part {
        for (self.parts) |p| {
            if (p.filename != null and std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

fn isMultipartContentType(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(body_mod.mediaTypeOf(value), "multipart/form-data");
}

/// The boundary parameter of a multipart Content-Type, unquoted. Null when
/// absent or violating RFC 2046's 1–70 length bound.
fn boundaryOf(ct: []const u8) ?[]const u8 {
    var it: ParamIterator = .{ .rest = ct };
    _ = it.next(); // the media type itself
    while (it.next()) |param_raw| {
        const param = std.mem.trim(u8, param_raw, " \t");
        if (std.ascii.startsWithIgnoreCase(param, "boundary=")) {
            const v = unquote(param["boundary=".len..]);
            if (v.len == 0 or v.len > 70) return null;
            return v;
        }
    }
    return null;
}

fn parse(
    arena: std.mem.Allocator,
    body: []const u8,
    boundary: []const u8,
) error{ InvalidMultipartBody, OutOfMemory }![]const Multipart.Part {
    // Parts are framed by "\r\n--boundary"; the first delimiter omits the
    // leading CRLF when there is no preamble (RFC 2046).
    const delim = try std.mem.concat(arena, u8, &.{ "\r\n--", boundary });
    var parts: std.ArrayList(Multipart.Part) = .empty;

    var pos: usize = 0;
    if (std.mem.startsWith(u8, body, delim[2..])) {
        pos = delim.len - 2;
    } else if (std.mem.indexOf(u8, body, delim)) |i| {
        pos = i + delim.len;
    } else return error.InvalidMultipartBody;

    while (true) {
        // Transport padding after the boundary line (RFC 2046).
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) pos += 1;
        if (std.mem.startsWith(u8, body[pos..], "--")) break; // close delimiter
        if (!std.mem.startsWith(u8, body[pos..], "\r\n")) return error.InvalidMultipartBody;
        pos += 2;

        const hdr_end = std.mem.indexOfPos(u8, body, pos, "\r\n\r\n") orelse
            return error.InvalidMultipartBody;
        var part = try parsePartHeaders(body[pos..hdr_end]);
        // RFC 2046 allows omitting the part body entirely, in which case the
        // header-terminating CRLF doubles as the delimiter's leading CRLF —
        // so search from hdr_end + 2, not past the blank line.
        const after_headers = hdr_end + 2;
        const data_end = std.mem.indexOfPos(u8, body, after_headers, delim) orelse
            return error.InvalidMultipartBody;
        part.data = if (data_end == after_headers) "" else body[hdr_end + 4 .. data_end];
        try parts.append(arena, part);
        pos = data_end + delim.len;
    }
    return parts.items;
}

/// Parses one part's header block (Content-Disposition is mandatory and
/// must carry `name`); `data` is left empty for the caller to fill.
fn parsePartHeaders(raw: []const u8) error{InvalidMultipartBody}!Multipart.Part {
    var name: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    var content_type: ?[]const u8 = null;

    var lines = std.mem.splitSequence(u8, raw, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse
            return error.InvalidMultipartBody;
        const hname = std.mem.trim(u8, line[0..colon], " \t");
        const hval = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(hname, "content-disposition")) {
            var it: ParamIterator = .{ .rest = hval };
            const disp = std.mem.trim(u8, it.next() orelse "", " \t");
            if (!std.ascii.eqlIgnoreCase(disp, "form-data")) return error.InvalidMultipartBody;
            while (it.next()) |param_raw| {
                const param = std.mem.trim(u8, param_raw, " \t");
                if (std.ascii.startsWithIgnoreCase(param, "name=")) {
                    name = unquote(param["name=".len..]);
                } else if (std.ascii.startsWithIgnoreCase(param, "filename=")) {
                    filename = unquote(param["filename=".len..]);
                }
            }
        } else if (std.ascii.eqlIgnoreCase(hname, "content-type")) {
            content_type = hval;
        }
    }
    return .{
        .name = name orelse return error.InvalidMultipartBody,
        .filename = filename,
        .content_type = content_type,
        .data = "",
    };
}

/// Splits header parameters on ';', but not inside double quotes — so a
/// quoted filename may contain semicolons.
const ParamIterator = struct {
    rest: []const u8,

    fn next(self: *ParamIterator) ?[]const u8 {
        if (self.rest.len == 0) return null;
        var in_quotes = false;
        var i: usize = 0;
        while (i < self.rest.len) : (i += 1) {
            switch (self.rest[i]) {
                '"' => in_quotes = !in_quotes,
                ';' => if (!in_quotes) break,
                else => {},
            }
        }
        const out = self.rest[0..i];
        self.rest = if (i < self.rest.len) self.rest[i + 1 ..] else self.rest[0..0];
        return out;
    }
};

fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    return v;
}

// ── Tests ────────────────────────────────────────────────────────────────

const t = std.testing;

fn testParse(arena: std.mem.Allocator, body: []const u8) ![]const Multipart.Part {
    return parse(arena, body, "XX");
}

test "parse: text field + file part, zero-copy data" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "--XX\r\n" ++
        "content-disposition: form-data; name=\"note\"\r\n" ++
        "\r\n" ++
        "hello\r\n" ++
        "--XX\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"a;b.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "line1\r\nline2\r\n" ++
        "--XX--\r\n";
    const parts = try testParse(arena, body);

    try t.expectEqual(2, parts.len);
    try t.expectEqualStrings("note", parts[0].name);
    try t.expectEqual(null, parts[0].filename);
    try t.expectEqualStrings("hello", parts[0].data);
    try t.expectEqualStrings("a;b.txt", parts[1].filename.?); // quoted ';' survives
    try t.expectEqualStrings("text/plain", parts[1].content_type.?);
    try t.expectEqualStrings("line1\r\nline2", parts[1].data);
    const off = std.mem.indexOf(u8, body, "hello").?;
    try t.expectEqual(body.ptr + off, parts[0].data.ptr); // borrows, no copy
}

test "parse: preamble, transport padding, empty part list" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Preamble before the first delimiter is ignored; padding after the
    // boundary line is tolerated.
    const parts = try testParse(arena, "preamble\r\n--XX  \r\n" ++
        "content-disposition: form-data; name=x\r\n\r\nv\r\n--XX--");
    try t.expectEqual(1, parts.len);
    try t.expectEqualStrings("v", parts[0].data);

    const empty = try testParse(arena, "--XX--\r\n");
    try t.expectEqual(0, empty.len);
}

test "parse: part with omitted body (RFC 2046 optional body)" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The header-terminating CRLF doubles as the delimiter's leading CRLF.
    const parts = try testParse(arena,
        "--XX\r\ncontent-disposition: form-data; name=x\r\n\r\n--XX--");
    try t.expectEqual(1, parts.len);
    try t.expectEqualStrings("", parts[0].data);

    // Explicit blank line + empty data still parses as empty.
    const parts2 = try testParse(arena,
        "--XX\r\ncontent-disposition: form-data; name=x\r\n\r\n\r\n--XX--");
    try t.expectEqual(1, parts2.len);
    try t.expectEqualStrings("", parts2[0].data);
}

test "parse: malformed bodies are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No delimiter at all.
    try t.expectError(error.InvalidMultipartBody, testParse(arena, "junk"));
    // Unterminated: no close delimiter after the part.
    try t.expectError(error.InvalidMultipartBody, testParse(arena,
        "--XX\r\ncontent-disposition: form-data; name=x\r\n\r\nv"));
    // Part without Content-Disposition name.
    try t.expectError(error.InvalidMultipartBody, testParse(arena,
        "--XX\r\ncontent-type: text/plain\r\n\r\nv\r\n--XX--"));
    // Content-Disposition that is not form-data.
    try t.expectError(error.InvalidMultipartBody, testParse(arena,
        "--XX\r\ncontent-disposition: attachment; name=x\r\n\r\nv\r\n--XX--"));
}

test "boundaryOf: plain, quoted, missing, oversized" {
    try t.expectEqualStrings("abc", boundaryOf("multipart/form-data; boundary=abc").?);
    try t.expectEqualStrings("a b", boundaryOf("multipart/form-data; boundary=\"a b\"").?);
    try t.expectEqualStrings("x", boundaryOf("multipart/form-data; charset=utf-8; boundary=x").?);
    try t.expectEqual(null, boundaryOf("multipart/form-data"));
    try t.expectEqual(null, boundaryOf("multipart/form-data; boundary="));
    try t.expectEqual(null, boundaryOf("multipart/form-data; boundary=" ++ "a" ** 71));
}

test "field/file accessors pick by kind" {
    const parts = [_]Multipart.Part{
        .{ .name = "a", .data = "text" },
        .{ .name = "a", .filename = "f.bin", .data = "bytes" },
    };
    const mp: Multipart = .{ .parts = &parts };
    try t.expectEqualStrings("text", mp.field("a").?);
    try t.expectEqualStrings("bytes", mp.file("a").?.data);
    try t.expectEqual(null, mp.field("missing"));
    try t.expectEqual(null, mp.file("missing"));
}
