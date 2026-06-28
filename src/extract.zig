//! Extractors and response conversion.
//!
//! `bind` digests a typed handler signature at comptime into the uniform
//! thunk stored in the route tree. Extractor contracts (comptime duck
//! typing):
//!   - `fromRequestParts(ctx) !Self` — reads only the head; any number.
//!   - `fromRequest(ctx) !Self`      — consumes the body; at most one and
//!                                     it must be the last parameter.
//! Violations are @compileErrors at the registration site, naming the
//! parameter position and the reason — the DX bar this design sets.
//!
//! Response side: a handler's return value answers via `toResponse(ctx)`
//! duck typing; `[]const u8` and `void` are accepted directly. Errors
//! propagate to the recover middleware for status mapping.

const std = @import("std");
const talon = @import("talon");
const context_mod = @import("context.zig");
const endpoint_mod = @import("endpoint.zig");
const state_mod = @import("state.zig");
const scalar = @import("scalar.zig");
const cookie_mod = @import("cookie.zig");

/// The aggregate of every built-in extractor's failure modes — the cookie
/// extractor's included — so a caller can `catch` one set to handle any
/// extraction error. Each extractor still returns only its own subset.
pub const ExtractError = cookie_mod.ExtractError || error{
    MissingQueryParam,
    InvalidQueryParam,
    MissingPathParam,
    InvalidPathParam,
    InvalidJsonBody,
    /// Body absent or its Content-Type is not application/x-www-form-urlencoded.
    InvalidFormBody,
    MissingFormField,
    InvalidFormField,
    /// A streamed body exceeded the server's `max_body_size` (413). Only
    /// chunked bodies reach this — oversized Content-Length bodies are
    /// rejected by talon before the handler runs.
    PayloadTooLarge,
};

// ── Handler binding ──────────────────────────────────────────────────────

pub fn bind(comptime State: type, comptime handler: anytype) endpoint_mod.Handler {
    const Ctx = context_mod.Context(State);
    const H = @TypeOf(handler);
    const info = @typeInfo(H);
    if (info != .@"fn") {
        @compileError("wing: route handler must be a function, got " ++ @typeName(H));
    }
    const fn_info = info.@"fn";
    const params = fn_info.params;
    if (params.len == 0 or params[0].type != *Ctx) {
        @compileError("wing: handler's first parameter must be *wing.Context(State) (= *" ++
            @typeName(Ctx) ++ ")");
    }

    // Classify every extractor parameter up front so signature mistakes
    // surface as one readable error at the registration site.
    comptime var body_consumer_at: ?usize = null;
    comptime {
        for (params[1..], 1..) |p, i| {
            const P = p.type orelse @compileError(std.fmt.comptimePrint(
                "wing: handler parameter #{d} cannot be anytype/generic — " ++
                    "extractor binding needs a concrete type",
                .{i + 1},
            ));
            switch (classify(State, P, i)) {
                .body => {
                    if (body_consumer_at) |prev| @compileError(std.fmt.comptimePrint(
                        "wing: handler parameter #{d} ({s}) consumes the body, " ++
                            "but parameter #{d} already does — only one body extractor per handler",
                        .{ i + 1, @typeName(P), prev + 1 },
                    ));
                    body_consumer_at = i;
                },
                .parts, .state_ptr => {},
            }
        }
        if (body_consumer_at) |at| {
            if (at != params.len - 1) {
                const P = params[at].type.?;
                @compileError(std.fmt.comptimePrint(
                    "wing: handler parameter #{d} ({s}) consumes the body and must be " ++
                        "the last parameter, but parameter #{d} comes after it",
                    .{ at + 1, @typeName(P), at + 2 },
                ));
            }
        }
        validateReturn(fn_info.return_type.?);
    }

    return struct {
        fn thunk(ptr: *anyopaque) anyerror!void {
            const ctx: *Ctx = @ptrCast(@alignCast(ptr));
            var args: std.meta.ArgsTuple(H) = undefined;
            args[0] = ctx;
            inline for (params[1..], 1..) |p, i| {
                args[i] = try extractArg(State, p.type.?, i, ctx);
            }
            const Ret = fn_info.return_type.?;
            if (@typeInfo(Ret) == .error_union) {
                try writeResponse(ctx, try @call(.auto, handler, args));
            } else {
                try writeResponse(ctx, @call(.auto, handler, args));
            }
        }
    }.thunk;
}

const ParamKind = enum { parts, body, state_ptr };

fn classify(comptime State: type, comptime P: type, comptime index: usize) ParamKind {
    if (@typeInfo(P) == .pointer and @typeInfo(P).pointer.size == .one) {
        const T = @typeInfo(P).pointer.child;
        const n = state_mod.fieldCountOfType(State, T);
        if (n == 1) return .state_ptr;
        if (n > 1) @compileError(std.fmt.comptimePrint(
            "wing: handler parameter #{d} (*{s}): State has {d} fields of type {s} — " ++
                "projection is ambiguous (Zig cannot reflect parameter names). " ++
                "Wrap one field in a distinct struct, or read it via ctx.state",
            .{ index + 1, @typeName(T), n, @typeName(T) },
        ));
        @compileError(std.fmt.comptimePrint(
            "wing: handler parameter #{d} (*{s}): State {s} has no field of type {s}",
            .{ index + 1, @typeName(T), @typeName(State), @typeName(T) },
        ));
    }
    if (@typeInfo(P) == .@"struct") {
        if (@hasDecl(P, "fromRequest")) return .body;
        if (@hasDecl(P, "fromRequestParts")) return .parts;
    }
    @compileError(std.fmt.comptimePrint(
        "wing: handler parameter #{d} ({s}) is not an extractor — expected a type with " ++
            "fromRequestParts/fromRequest (wing.Query, wing.Json, wing.Path, ...) or a " ++
            "pointer to a unique State field",
        .{ index + 1, @typeName(P) },
    ));
}

fn extractArg(
    comptime State: type,
    comptime P: type,
    comptime index: usize,
    ctx: anytype,
) !P {
    return switch (comptime classify(State, P, index)) {
        .state_ptr => state_mod.project(State, @typeInfo(P).pointer.child, ctx.state),
        .body => P.fromRequest(ctx),
        .parts => P.fromRequestParts(ctx),
    };
}

// ── Response conversion ──────────────────────────────────────────────────

fn validateReturn(comptime Ret: type) void {
    const Payload = if (@typeInfo(Ret) == .error_union)
        @typeInfo(Ret).error_union.payload
    else
        Ret;
    if (Payload == void) return;
    if (Payload == []const u8 or Payload == []u8) return;
    if (@typeInfo(Payload) == .@"struct" and @hasDecl(Payload, "toResponse")) return;
    @compileError("wing: handler return type " ++ @typeName(Payload) ++
        " is not convertible to a response — return void, []const u8, or a type " ++
        "with 'pub fn toResponse(self, ctx) !void' (wing.Json, wing.Created, wing.Redirect, ...)");
}

fn writeResponse(ctx: anytype, payload: anytype) !void {
    const P = @TypeOf(payload);
    if (P == void) {
        // Plain `!void` handlers usually respond through ctx.res themselves;
        // cover the forgot-to-respond case so the connection stays correct.
        if (!ctx.res.written) try ctx.respond("", .{});
        return;
    }
    if (P == []const u8 or P == []u8) {
        try ctx.respond(payload, .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        });
        return;
    }
    try payload.toResponse(ctx);
}

/// Serializes `value` as JSON into the request arena.
fn jsonStringifyArena(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    stringify.write(value) catch return error.OutOfMemory;
    return out.written();
}

/// Classifies a failed body stream. A size-limit breach becomes
/// `PayloadTooLarge` (413); every other failure keeps the caller's generic
/// body error (400). Shared by the `Json` and `Form` body extractors.
fn bodyReadError(ctx: anytype, generic: ExtractError) ExtractError {
    if (ctx.req.bodyError()) |berr| {
        if (berr == error.BodyTooLarge) return error.PayloadTooLarge;
    }
    return generic;
}

// ── Built-in extractors / responders ─────────────────────────────────────

/// JSON in both directions: as a parameter it consumes and parses the
/// request body (fromRequest); as a return type it serializes with 200.
pub fn Json(comptime T: type) type {
    return struct {
        value: T,

        pub fn fromRequest(ctx: anytype) !@This() {
            var collected: std.Io.Writer.Allocating = .init(ctx.arena);
            _ = ctx.req.bodyReader().streamRemaining(&collected.writer) catch
                return bodyReadError(ctx, error.InvalidJsonBody);
            const value = std.json.parseFromSliceLeaky(
                T,
                ctx.arena,
                collected.written(),
                .{ .allocate = .alloc_always },
            ) catch return error.InvalidJsonBody;
            return .{ .value = value };
        }

        pub fn toResponse(self: @This(), ctx: anytype) !void {
            try ctx.respond(try jsonStringifyArena(ctx.arena, self.value), .{
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
        }
    };
}

/// 201 Created with a JSON body and optional Location header.
pub fn Created(comptime T: type) type {
    return struct {
        value: T,
        location: []const u8 = "",

        pub fn toResponse(self: @This(), ctx: anytype) !void {
            const body = try jsonStringifyArena(ctx.arena, self.value);
            if (self.location.len > 0) {
                try ctx.respond(body, .{
                    .status = .created,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                        .{ .name = "location", .value = self.location },
                    },
                });
            } else {
                try ctx.respond(body, .{
                    .status = .created,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                    },
                });
            }
        }
    };
}

pub const Redirect = struct {
    location: []const u8,
    status: talon.http.Status = .found,

    pub fn toResponse(self: Redirect, ctx: anytype) !void {
        try ctx.respond("", .{
            .status = self.status,
            .extra_headers = &.{.{ .name = "location", .value = self.location }},
        });
    }
};

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
                .value = parseUrlEncoded(T, ctx.arena, raw) catch |e| switch (e) {
                    error.MissingField => return error.MissingQueryParam,
                    error.InvalidField => return error.InvalidQueryParam,
                    else => |other| return other, // OutOfMemory
                },
            };
        }
    };
}

/// Parses an `application/x-www-form-urlencoded` request body into `T`
/// (fromRequest). The body grammar matches the query string, so it shares
/// `Query`'s parser — only the source (body vs URL) and the strict
/// Content-Type guard differ. Field-type and required/optional rules are
/// identical to `Query`. `multipart/form-data` is out of scope.
pub fn Form(comptime T: type) type {
    return struct {
        value: T,

        pub fn fromRequest(ctx: anytype) !@This() {
            const ct = ctx.req.header("content-type") orelse return error.InvalidFormBody;
            if (!isFormContentType(ct)) return error.InvalidFormBody;

            var collected: std.Io.Writer.Allocating = .init(ctx.arena);
            _ = ctx.req.bodyReader().streamRemaining(&collected.writer) catch
                return bodyReadError(ctx, error.InvalidFormBody);

            return .{
                .value = parseUrlEncoded(T, ctx.arena, collected.written()) catch |e| switch (e) {
                    error.MissingField => return error.MissingFormField,
                    error.InvalidField => return error.InvalidFormField,
                    else => |other| return other, // OutOfMemory
                },
            };
        }
    };
}

/// True when `value` is the form media type, ignoring optional parameters
/// (`; charset=...`) and case — media types are case-insensitive (RFC 9110).
fn isFormContentType(value: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media_type = std.mem.trim(u8, value[0..end], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/x-www-form-urlencoded");
}

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

/// Shared `x-www-form-urlencoded` parser for `Query` (URL) and `Form` (body):
/// the two grammars are identical. Returns neutral `MissingField`/`InvalidField`
/// errors so each caller can remap them to its own contract-specific names. The
/// error set is declared (not inferred) so callers can `switch` on it even when
/// a given `T` makes the `MissingField` branch comptime-unreachable.
fn parseUrlEncoded(
    comptime T: type,
    arena: std.mem.Allocator,
    raw: []const u8,
) error{ MissingField, InvalidField, OutOfMemory }!T {
    const fields = @typeInfo(T).@"struct".fields;
    var value: T = undefined;
    var seen = [_]bool{false} ** fields.len;

    var it = std.mem.splitScalar(u8, raw, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const raw_key = if (eq) |i| pair[0..i] else pair;
        const raw_val = if (eq) |i| pair[i + 1 ..] else "";
        const key = try urlDecode(arena, raw_key);
        const val = try urlDecode(arena, raw_val);
        inline for (fields, 0..) |f, fi| {
            if (std.mem.eql(u8, f.name, key)) {
                @field(value, f.name) = scalar.parseScalar(f.type, val) catch
                    return error.InvalidField;
                seen[fi] = true;
            }
        }
        // Unknown keys are ignored: forward-compatible contracts.
    }

    inline for (fields, 0..) |f, fi| {
        if (!seen[fi]) {
            if (f.defaultValue()) |d| {
                @field(value, f.name) = d;
            } else if (@typeInfo(f.type) == .optional) {
                @field(value, f.name) = null;
            } else {
                return error.MissingField;
            }
        }
    }
    return value;
}

/// Percent-decoding plus '+' → space. Borrows `raw` when no decoding is
/// needed (the common case); otherwise copies into the arena.
fn urlDecode(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, raw, "%+") == null) return raw;
    var out = try arena.alloc(u8, raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        switch (raw[i]) {
            '+' => out[n] = ' ',
            '%' => {
                if (i + 2 >= raw.len) return error.InvalidField;
                out[n] = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch
                    return error.InvalidField;
                i += 2;
            },
            else => out[n] = raw[i],
        }
        n += 1;
    }
    return out[0..n];
}

// ── Tests ────────────────────────────────────────────────────────────────

test "parseUrlEncoded: types, defaults, optionals, required" {
    const P = struct {
        page: u32 = 1,
        per_page: u32 = 20,
        q: ?[]const u8,
        strict: bool = false,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p1 = try parseUrlEncoded(P, arena, "page=3&q=zig%20web&strict=true");
    try std.testing.expectEqual(3, p1.page);
    try std.testing.expectEqual(20, p1.per_page);
    try std.testing.expectEqualStrings("zig web", p1.q.?);
    try std.testing.expectEqual(true, p1.strict);

    const p2 = try parseUrlEncoded(P, arena, "");
    try std.testing.expectEqual(1, p2.page);
    try std.testing.expectEqual(null, p2.q);

    const R = struct { id: u64 };
    try std.testing.expectError(error.MissingField, parseUrlEncoded(R, arena, ""));
    try std.testing.expectError(error.InvalidField, parseUrlEncoded(R, arena, "id=abc"));
}

test "urlDecode: borrow fast path and decode path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = "hello";
    const decoded_plain = try urlDecode(arena, plain);
    try std.testing.expectEqual(plain.ptr, decoded_plain.ptr); // borrowed

    try std.testing.expectEqualStrings("a b+c", try urlDecode(arena, "a+b%2Bc"));
    try std.testing.expectError(error.InvalidField, urlDecode(arena, "%2"));
    try std.testing.expectError(error.InvalidField, urlDecode(arena, "%zz"));
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
