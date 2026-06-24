//! Request Context.
//!
//! One Context per request, stack-allocated by the wing App adapter. All
//! slices (params, request_id) borrow per-request storage; lifetime is the
//! current request.

const std = @import("std");
const talon = @import("talon");
const endpoint_mod = @import("endpoint.zig");
const router_mod = @import("router.zig");

pub const max_path_params = 16;

/// Zero-allocation path parameter storage: slices borrow the URL buffer of
/// the current request.
pub const PathParams = struct {
    names: [max_path_params][]const u8 = undefined,
    values: [max_path_params][]const u8 = undefined,
    len: usize = 0,

    pub fn get(self: *const PathParams, name: []const u8) ?[]const u8 {
        for (self.names[0..self.len], self.values[0..self.len]) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }

    pub fn append(self: *PathParams, name: []const u8, value: []const u8) void {
        std.debug.assert(self.len < max_path_params);
        self.names[self.len] = name;
        self.values[self.len] = value;
        self.len += 1;
    }
};

pub fn Context(comptime State: type) type {
    return struct {
        req: *talon.http.Request,
        res: *talon.http.Response,
        /// Request-level arena (talon-managed, reset between requests).
        arena: std.mem.Allocator,
        state: *State,
        /// Filled by route_match; null until then or when unmatched.
        endpoint: ?*const endpoint_mod.Endpoint = null,
        params: PathParams = .{},
        /// Set by the request_id middleware; borrows request storage.
        request_id: []const u8 = "",
        /// Headers accumulated by middleware (cors, request_id), merged into
        /// the response by `respond`. talon writes the head exactly once, so
        /// post-hoc injection needs this indirection. Arena-backed.
        extra_headers: std.ArrayList(talon.http.Header) = .empty,
        /// Needed by route_match; not part of the user-facing contract.
        router: *const router_mod.Router(State),

        pub const WingState = State;

        const Self = @This();

        /// Queues a header for the eventual response. Middleware-facing.
        pub fn addHeader(self: *Self, name: []const u8, value: []const u8) !void {
            try self.extra_headers.append(self.arena, .{ .name = name, .value = value });
        }

        /// Respond with middleware-accumulated headers merged in. wing's
        /// built-in responders all come through here; handlers calling
        /// `ctx.res.respond` directly bypass accumulated headers.
        pub fn respond(
            self: *Self,
            body: []const u8,
            options: talon.http.Response.RespondOptions,
        ) !void {
            if (self.extra_headers.items.len == 0) {
                return self.res.respond(body, options);
            }
            const merged = try self.arena.alloc(
                talon.http.Header,
                self.extra_headers.items.len + options.extra_headers.len,
            );
            @memcpy(merged[0..self.extra_headers.items.len], self.extra_headers.items);
            @memcpy(merged[self.extra_headers.items.len..], options.extra_headers);
            var opts = options;
            opts.extra_headers = merged;
            return self.res.respond(body, opts);
        }
    };
}
