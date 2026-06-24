//! Endpoint + Metadata: two-phase routing artifacts.
//!
//! Route match produces an Endpoint; downstream middleware (cors, auth,
//! rate limit) read its metadata to apply per-route policy — cross-cutting
//! concerns become "one middleware reading metadata" instead of one chain
//! per route group.

const std = @import("std");
const talon = @import("talon");
const zio = @import("zio");

/// Uniform handler thunk: the only dynamic dispatch point in wing.
/// The opaque pointer is `*Context(State)`; binding logic is comptime-baked.
pub const Handler = *const fn (*anyopaque) anyerror!void;

/// Route predicate beyond method/path (actix Guard). Runs during the
/// match phase; returning false makes the lookup continue as if the route
/// did not exist.
pub const Guard = *const fn (req: *const talon.http.Request) bool;

pub const Endpoint = struct {
    handler: Handler,
    metadata: Metadata,
};

/// Static per-route policy data, read by metadata-driven middleware.
/// Constructed at registration; never mutated afterwards.
pub const Metadata = struct {
    name: []const u8 = "",
    auth: ?AuthRequirement = null,
    rate_limit: ?RateLimit = null,
    cors: ?CorsPolicy = null,
    timeout: ?zio.Timeout = null,
};

pub const AuthRequirement = struct {
    role: []const u8 = "",
};

pub const RateLimit = struct {
    per_second: u32,
};

pub const CorsPolicy = struct {
    allow_origin: []const u8 = "*",
    allow_methods: []const u8 = "GET, POST, PUT, DELETE, PATCH, OPTIONS",
    allow_headers: []const u8 = "content-type, authorization",
    max_age_seconds: u32 = 600,
};

/// Registration-time options: metadata plus the match-phase guard.
pub const RouteOptions = struct {
    name: []const u8 = "",
    auth: ?AuthRequirement = null,
    rate_limit: ?RateLimit = null,
    cors: ?CorsPolicy = null,
    timeout: ?zio.Timeout = null,
    guard: ?Guard = null,

    pub fn metadata(self: RouteOptions) Metadata {
        return .{
            .name = self.name,
            .auth = self.auth,
            .rate_limit = self.rate_limit,
            .cors = self.cors,
            .timeout = self.timeout,
        };
    }
};

/// Guard factory: matches when the request Host header equals `host`.
pub fn hostIs(comptime host: []const u8) Guard {
    return struct {
        fn check(req: *const talon.http.Request) bool {
            const h = req.head.host orelse return false;
            return std.ascii.eqlIgnoreCase(h, host);
        }
    }.check;
}

/// Guard factory: matches when header `name` is present with value `value`.
pub fn headerIs(comptime name: []const u8, comptime value: []const u8) Guard {
    return struct {
        fn check(req: *const talon.http.Request) bool {
            const v = req.header(name) orelse return false;
            return std.mem.eql(u8, v, value);
        }
    }.check;
}
