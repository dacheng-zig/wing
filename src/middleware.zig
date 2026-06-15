//! Built-in request-level middleware (design doc §9).
//!
//! All middlewares are generic over the context type (anytype ctx), so one
//! definition serves every `Context(State)` instantiation — the comptime
//! version of tower's ecosystem effect (§7).
//!
//! First-phase set: recover, logger, request_id, route_match/execute (§6
//! standard pieces), cors, static (file-reading version; switches to talon
//! sendFile when the engine grows it). Deferred: timeout (needs an
//! engine-level deadline primitive to be race-free), compress (M3 per §13).

const std = @import("std");
const talon = @import("talon");
const zio = @import("zio");
const context_mod = @import("context.zig");

/// Capability provided by `route_match`, required by metadata-reading
/// middleware — ordering mistakes become compile errors (§6, talon §7).
pub const RouteMatched = struct {};

// ── Two-phase routing standard pieces (§6) ───────────────────────────────

/// Route match as a chain middleware: later middleware see *what will run*
/// (ctx.endpoint + metadata) before it runs. Unmatched requests short-
/// circuit to 405 (with Allow), the router fallback, or 404 — except CORS
/// preflights, which pass through for `cors` downstream to answer.
pub const route_match = struct {
    pub const provides = .{RouteMatched};

    pub fn run(ctx: anytype, next: anytype) anyerror!void {
        const path = pathOf(ctx.req.target());
        var method = ctx.req.method();
        // HEAD is served by GET endpoints; talon suppresses the body.
        if (method == .HEAD and
            ctx.router.match(.HEAD, path, ctx.req, &ctx.params) == null)
        {
            method = .GET;
        }

        if (ctx.router.match(method, path, ctx.req, &ctx.params)) |ep| {
            ctx.endpoint = ep;
            return next.call(ctx);
        }

        // CORS preflight for an existing route must reach `cors`, not 405.
        if (ctx.req.method() == .OPTIONS and
            ctx.req.header("access-control-request-method") != null)
        {
            return next.call(ctx);
        }

        const allowed = ctx.router.allowedMethods(path, ctx.req);
        if (allowed.count() > 0) {
            try ctx.respond("method not allowed\n", .{
                .status = .method_not_allowed,
                .extra_headers = &.{.{ .name = "allow", .value = try allowHeader(ctx.arena, allowed) }},
            });
            return;
        }

        if (ctx.router.fallback_handler) |fb| {
            return fb(@ptrCast(ctx));
        }
        try ctx.respond("not found\n", .{ .status = .not_found });
    }
};

/// The chain terminal (§6 `execute`): invokes the matched endpoint thunk.
/// Returns the typed terminal fn for `Context(State)`.
pub fn executeTerminal(comptime State: type) fn (*context_mod.Context(State)) anyerror!void {
    return struct {
        fn execute(ctx: *context_mod.Context(State)) anyerror!void {
            if (ctx.endpoint) |ep| {
                return ep.handler(@ptrCast(ctx));
            }
            // Reachable only for pass-through unmatched requests (e.g. a
            // preflight no cors middleware answered).
            if (!ctx.res.written) try ctx.respond("not found\n", .{ .status = .not_found });
        }
    }.execute;
}

// ── Error boundary (§9 recover) ──────────────────────────────────────────

/// Error boundary with a custom error→status mapping.
pub fn recoverWith(comptime mapper: fn (anyerror) talon.http.Status) type {
    return struct {
        pub fn run(ctx: anytype, next: anytype) anyerror!void {
            next.call(ctx) catch |err| {
                // Head already sent: nothing safe to write; propagate so
                // talon tears the connection down instead of smuggling a
                // half response.
                if (ctx.res.written) return err;
                const status = mapper(err);
                std.log.scoped(.wing).warn("handler error {t} -> {d} {s}", .{
                    err, @intFromEnum(status), ctx.req.target(),
                });
                try ctx.respond(status.phrase() orelse "error", .{ .status = status });
            };
        }
    };
}

/// Error boundary with the default mapping (extract errors → 400, NotFound
/// → 404, anything else → 500).
pub const recover = recoverWith(defaultErrorStatus);

pub fn defaultErrorStatus(err: anyerror) talon.http.Status {
    return switch (err) {
        error.MissingQueryParam,
        error.InvalidQueryParam,
        error.MissingPathParam,
        error.InvalidPathParam,
        error.InvalidJsonBody,
        => .bad_request,
        error.NotFound => .not_found,
        error.Unauthorized => .unauthorized,
        error.Forbidden => .forbidden,
        else => .internal_server_error,
    };
}

// ── Observability (§9 logger, request_id) ────────────────────────────────

pub const logger = struct {
    pub fn run(ctx: anytype, next: anytype) anyerror!void {
        var stopwatch = zio.Stopwatch.start();
        const target = ctx.req.target();
        next.call(ctx) catch |err| {
            std.log.scoped(.wing).err("{s} {s} failed: {t} ({f})", .{
                @tagName(ctx.req.method()),
                target,
                err,
                stopwatch.read(),
            });
            return err;
        };
        std.log.scoped(.wing).info("{s} {s} ({f})", .{
            @tagName(ctx.req.method()),
            target,
            stopwatch.read(),
        });
    }
};

/// Tags the request with a process-unique id: `ctx.request_id` for handlers
/// and an `x-request-id` response header (via ctx.respond merging).
pub const request_id = struct {
    var counter: std.atomic.Value(u64) = .init(0);

    pub fn run(ctx: anytype, next: anytype) anyerror!void {
        const id = counter.fetchAdd(1, .monotonic);
        const buf = try std.fmt.allocPrint(ctx.arena, "{x:0>16}", .{id});
        ctx.request_id = buf;
        try ctx.addHeader("x-request-id", buf);
        return next.call(ctx);
    }
};

// ── CORS (§9, metadata-driven per §6) ────────────────────────────────────

/// Reads the per-route `metadata.cors` policy. Preflights (OPTIONS +
/// Access-Control-Request-Method) are answered for the *target* method's
/// route; simple requests get response headers queued on the context.
pub const cors = struct {
    pub const requires = .{RouteMatched};

    pub fn run(ctx: anytype, next: anytype) anyerror!void {
        const req = ctx.req;
        if (req.method() == .OPTIONS) {
            if (req.header("access-control-request-method")) |acrm| {
                return preflight(ctx, next, acrm);
            }
        }
        if (ctx.endpoint) |ep| {
            if (ep.metadata.cors) |policy| {
                if (req.header("origin") != null) {
                    try ctx.addHeader("access-control-allow-origin", policy.allow_origin);
                }
            }
        }
        return next.call(ctx);
    }

    fn preflight(ctx: anytype, next: anytype, acrm: []const u8) anyerror!void {
        const method = std.meta.stringToEnum(talon.http.Method, acrm) orelse .other;
        const path = pathOf(ctx.req.target());
        var scratch: context_mod.PathParams = .{};
        const ep = ctx.router.match(method, path, ctx.req, &scratch) orelse
            return next.call(ctx);
        const policy = ep.metadata.cors orelse return next.call(ctx);

        var max_age_buf: [12]u8 = undefined;
        const max_age = std.fmt.bufPrint(&max_age_buf, "{d}", .{policy.max_age_seconds}) catch
            unreachable;
        try ctx.respond("", .{
            .status = .no_content,
            .extra_headers = &.{
                .{ .name = "access-control-allow-origin", .value = policy.allow_origin },
                .{ .name = "access-control-allow-methods", .value = policy.allow_methods },
                .{ .name = "access-control-allow-headers", .value = policy.allow_headers },
                .{ .name = "access-control-max-age", .value = max_age },
            },
        });
    }
};

// ── Static files (§9) ────────────────────────────────────────────────────

/// Returns a *handler* serving files from `root_dir`; mount it on a
/// wildcard route: `router.get("/assets/*path", wing.static(State, "www"))`.
/// Path traversal is rejected before any filesystem access. Reads through
/// the request arena today; switches to talon sendFile when available.
pub fn static(comptime State: type, comptime root_dir: []const u8) fn (*context_mod.Context(State)) anyerror!void {
    return struct {
        fn serve(ctx: *context_mod.Context(State)) anyerror!void {
            const rel = ctx.params.get("path") orelse return error.NotFound;
            if (!pathIsSafe(rel)) return error.NotFound;

            const full = try std.fs.path.join(ctx.arena, &.{ root_dir, rel });
            const file = zio.Dir.cwd().openFile(full, .{}) catch return error.NotFound;
            defer file.close();

            var read_buf: [4096]u8 = undefined;
            var reader = file.reader(&read_buf);
            var collected: std.Io.Writer.Allocating = .init(ctx.arena);
            _ = reader.interface.streamRemaining(&collected.writer) catch
                return error.NotFound;

            try ctx.respond(collected.written(), .{
                .extra_headers = &.{.{ .name = "content-type", .value = contentTypeOf(rel) }},
            });
        }
    }.serve;
}

/// Rejects traversal ("..", absolute, NUL) before touching the filesystem.
fn pathIsSafe(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (rel[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

fn contentTypeOf(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const map = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".css", "text/css" },
        .{ ".js", "application/javascript" },
        .{ ".json", "application/json" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".svg", "image/svg+xml" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".wasm", "application/wasm" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

// ── Shared helpers ───────────────────────────────────────────────────────

/// Request target with the query string stripped: the routable path.
fn pathOf(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |i| return target[0..i];
    return target;
}

/// "GET, POST" — built in the request arena for the 405 Allow header.
fn allowHeader(arena: std.mem.Allocator, set: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var first = true;
    var it = set.iterator();
    while (it.next()) |m| {
        if (!first) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.writeAll(@tagName(m)) catch return error.OutOfMemory;
        first = false;
    }
    return out.written();
}

// ── Tests ────────────────────────────────────────────────────────────────

test "pathOf strips the query string" {
    try std.testing.expectEqualStrings("/users", pathOf("/users?page=2"));
    try std.testing.expectEqualStrings("/users", pathOf("/users"));
}

test "pathIsSafe rejects traversal" {
    try std.testing.expect(pathIsSafe("css/site.css"));
    try std.testing.expect(!pathIsSafe("../etc/passwd"));
    try std.testing.expect(!pathIsSafe("a/../../b"));
    try std.testing.expect(!pathIsSafe("/abs"));
    try std.testing.expect(!pathIsSafe(""));
}

test "contentTypeOf maps extensions" {
    try std.testing.expectEqualStrings("text/css", contentTypeOf("a/b.css"));
    try std.testing.expectEqualStrings("application/octet-stream", contentTypeOf("a/b.bin"));
}
