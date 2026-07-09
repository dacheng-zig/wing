//! Router: segment-granularity radix tree with value-semantic composition.
//!
//! - One tree per HTTP method; lookup is zero-allocation, path parameters
//!   borrow the URL buffer.
//! - Segment kinds: static, `:param`, `*wildcard` (terminal, captures rest).
//! - Precedence static > param > wildcard, with backtracking so `/u/new`
//!   and `/u/:id` coexist.
//! - `nest`/`merge` are startup-time tree grafts with move semantics: the
//!   source router is left empty (safe to deinit), endpoints transfer
//!   ownership. Conflicts are registration-time errors, never silent.
//! - Guards hang on tree entries; a failing guard continues the match
//!   as if the route did not exist.

const std = @import("std");
const talon = @import("talon");
const endpoint_mod = @import("endpoint.zig");
const context_mod = @import("context.zig");
const binding = @import("binding.zig");

const Endpoint = endpoint_mod.Endpoint;
const Guard = endpoint_mod.Guard;
const Handler = endpoint_mod.Handler;
const RouteOptions = endpoint_mod.RouteOptions;
const PathParams = context_mod.PathParams;

pub const RouteError = error{
    /// Path must start with '/'; '*' segment must be last; param name empty.
    MalformedPath,
    /// Two routes claim the same method+path (or conflicting param names).
    RouteConflict,
    OutOfMemory,
};

const method_count = @typeInfo(talon.http.Method).@"enum".fields.len;

pub const MethodSet = std.EnumSet(talon.http.Method);

pub fn Router(comptime State: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        trees: [method_count]Node,
        fallback_handler: ?Handler = null,

        const Entry = struct {
            guard: ?Guard,
            endpoint: *Endpoint,
        };

        const Node = struct {
            /// Static segment label ("" for roots and non-static nodes).
            label: []const u8 = "",
            /// Param/wildcard capture name ("" for static nodes).
            capture: []const u8 = "",
            entries: std.ArrayList(Entry) = .empty,
            static_children: std.ArrayList(*Node) = .empty,
            param_child: ?*Node = null,
            wildcard_child: ?*Node = null,

            fn deinit(self: *Node, gpa: std.mem.Allocator) void {
                for (self.entries.items) |e| gpa.destroy(e.endpoint);
                self.entries.deinit(gpa);
                for (self.static_children.items) |child| {
                    child.deinit(gpa);
                    gpa.destroy(child);
                }
                self.static_children.deinit(gpa);
                if (self.param_child) |child| {
                    child.deinit(gpa);
                    gpa.destroy(child);
                }
                if (self.wildcard_child) |child| {
                    child.deinit(gpa);
                    gpa.destroy(child);
                }
                self.* = .{};
            }

            fn findStatic(self: *const Node, seg: []const u8) ?*Node {
                for (self.static_children.items) |child| {
                    if (std.mem.eql(u8, child.label, seg)) return child;
                }
                return null;
            }
        };

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa, .trees = @splat(.{}) };
        }

        pub fn deinit(self: *Self) void {
            for (&self.trees) |*root| root.deinit(self.gpa);
        }

        // ── Registration ────────────────────────────────────────────────

        /// Full registration form: method + path + typed handler + options
        /// (metadata + guard). Binding happens here at comptime.
        pub fn add(
            self: *Self,
            method: talon.http.Method,
            path: []const u8,
            comptime handler: anytype,
            options: RouteOptions,
        ) RouteError!void {
            try self.addThunk(method, path, binding.bind(State, handler), options);
        }

        pub fn get(self: *Self, path: []const u8, comptime handler: anytype) RouteError!void {
            try self.add(.GET, path, handler, .{});
        }

        pub fn post(self: *Self, path: []const u8, comptime handler: anytype) RouteError!void {
            try self.add(.POST, path, handler, .{});
        }

        pub fn put(self: *Self, path: []const u8, comptime handler: anytype) RouteError!void {
            try self.add(.PUT, path, handler, .{});
        }

        pub fn delete(self: *Self, path: []const u8, comptime handler: anytype) RouteError!void {
            try self.add(.DELETE, path, handler, .{});
        }

        pub fn patch(self: *Self, path: []const u8, comptime handler: anytype) RouteError!void {
            try self.add(.PATCH, path, handler, .{});
        }

        /// Unmatched-request terminal. Replaces any previous fallback.
        pub fn fallback(self: *Self, comptime handler: anytype) void {
            self.fallback_handler = binding.bind(State, handler);
        }

        /// Pre-bound registration: used by `add` and by tree grafting.
        fn addThunk(
            self: *Self,
            method: talon.http.Method,
            path: []const u8,
            thunk: Handler,
            options: RouteOptions,
        ) RouteError!void {
            const ep = try self.gpa.create(Endpoint);
            errdefer self.gpa.destroy(ep);
            ep.* = .{ .handler = thunk, .metadata = options.metadata() };
            const node = try self.nodeForPath(&self.trees[@intFromEnum(method)], path);
            try addEntry(self.gpa, node, .{ .guard = options.guard, .endpoint = ep });
        }

        /// Walks/creates the node for `path`, validating segment grammar.
        fn nodeForPath(self: *Self, root: *Node, path: []const u8) RouteError!*Node {
            if (path.len == 0 or path[0] != '/') return error.MalformedPath;
            var node = root;
            var it = std.mem.splitScalar(u8, path[1..], '/');
            while (it.next()) |seg| {
                if (path.len == 1) break; // "/" → root itself
                if (seg.len > 0 and seg[0] == ':') {
                    const name = seg[1..];
                    if (name.len == 0) return error.MalformedPath;
                    if (node.param_child) |child| {
                        // One param name per position, or routes become ambiguous.
                        if (!std.mem.eql(u8, child.capture, name)) return error.RouteConflict;
                        node = child;
                    } else {
                        const child = try self.newChild(.{ .capture = name });
                        node.param_child = child;
                        node = child;
                    }
                } else if (seg.len > 0 and seg[0] == '*') {
                    const name = seg[1..];
                    if (name.len == 0) return error.MalformedPath;
                    if (it.next() != null) return error.MalformedPath; // '*' must be last
                    if (node.wildcard_child) |child| {
                        if (!std.mem.eql(u8, child.capture, name)) return error.RouteConflict;
                        node = child;
                    } else {
                        const child = try self.newChild(.{ .capture = name });
                        node.wildcard_child = child;
                        node = child;
                    }
                    break;
                } else {
                    if (node.findStatic(seg)) |child| {
                        node = child;
                    } else {
                        const child = try self.newChild(.{ .label = seg });
                        try node.static_children.append(self.gpa, child);
                        node = child;
                    }
                }
            }
            return node;
        }

        fn newChild(self: *Self, init_node: Node) RouteError!*Node {
            const child = try self.gpa.create(Node);
            child.* = init_node;
            return child;
        }

        /// Entry conflict rule: at most one guardless entry per node; guarded
        /// entries try in registration order, guardless last.
        fn addEntry(gpa: std.mem.Allocator, node: *Node, entry: Entry) RouteError!void {
            if (entry.guard == null) {
                for (node.entries.items) |e| {
                    if (e.guard == null) return error.RouteConflict;
                }
                try node.entries.append(gpa, entry);
            } else {
                // Insert before the guardless entry so guards stay specific-first.
                var insert_at: usize = node.entries.items.len;
                for (node.entries.items, 0..) |e, i| {
                    if (e.guard == null) {
                        insert_at = i;
                        break;
                    }
                }
                try node.entries.insert(gpa, insert_at, entry);
            }
        }

        // ── Composition ─────────────────────────────────────────────────

        /// Mounts `other` under `prefix` (sub-router "/" maps to the prefix
        /// itself). Move semantics: `other` ends up empty.
        pub fn nest(self: *Self, prefix: []const u8, other: *Self) RouteError!void {
            for (&self.trees, &other.trees) |*dst_root, *src_root| {
                if (emptyNode(src_root)) continue;
                const mount = try self.nodeForPath(dst_root, prefix);
                try self.graft(mount, src_root);
            }
        }

        /// Merges `other` at the root. Move semantics: `other` ends up empty.
        pub fn merge(self: *Self, other: *Self) RouteError!void {
            for (&self.trees, &other.trees) |*dst_root, *src_root| {
                try self.graft(dst_root, src_root);
            }
        }

        fn emptyNode(n: *const Node) bool {
            return n.entries.items.len == 0 and n.static_children.items.len == 0 and
                n.param_child == null and n.wildcard_child == null;
        }

        /// Moves `src`'s contents into `dst`; on success `src` is empty.
        /// Each item transfers atomically (added to dst, then removed from
        /// src), so a conflict error mid-graft leaves both trees partially
        /// merged but ownership-consistent and deinit-safe. Fine for a
        /// startup-time builder API: conflicts are fatal, not recovered.
        fn graft(self: *Self, dst: *Node, src: *Node) RouteError!void {
            const gpa = self.gpa;

            while (src.entries.items.len > 0) {
                const e = src.entries.items[src.entries.items.len - 1];
                try addEntry(gpa, dst, e);
                src.entries.items.len -= 1;
            }
            src.entries.deinit(gpa);
            src.entries = .empty;

            while (src.static_children.items.len > 0) {
                const src_child = src.static_children.items[src.static_children.items.len - 1];
                if (dst.findStatic(src_child.label)) |dst_child| {
                    try self.graft(dst_child, src_child);
                    _ = src.static_children.pop();
                    gpa.destroy(src_child);
                } else {
                    try dst.static_children.append(gpa, src_child);
                    _ = src.static_children.pop();
                }
            }
            src.static_children.deinit(gpa);
            src.static_children = .empty;

            if (src.param_child) |src_child| {
                if (dst.param_child) |dst_child| {
                    if (!std.mem.eql(u8, dst_child.capture, src_child.capture))
                        return error.RouteConflict;
                    try self.graft(dst_child, src_child);
                    src.param_child = null;
                    gpa.destroy(src_child);
                } else {
                    dst.param_child = src_child;
                    src.param_child = null;
                }
            }

            if (src.wildcard_child) |src_child| {
                if (dst.wildcard_child) |dst_child| {
                    if (!std.mem.eql(u8, dst_child.capture, src_child.capture))
                        return error.RouteConflict;
                    try self.graft(dst_child, src_child);
                    src.wildcard_child = null;
                    gpa.destroy(src_child);
                } else {
                    dst.wildcard_child = src_child;
                    src.wildcard_child = null;
                }
            }
        }

        // ── Matching ────────────────────────────────────────────────────

        /// Zero-allocation lookup. `params` slices borrow `path`'s buffer.
        /// Guarded entries consult `req`; a failing guard continues matching.
        pub fn match(
            self: *const Self,
            method: talon.http.Method,
            path: []const u8,
            req: *const talon.http.Request,
            params: *PathParams,
        ) ?*const Endpoint {
            if (path.len == 0 or path[0] != '/') return null;
            const root = &self.trees[@intFromEnum(method)];
            return matchNode(root, path[1..], path.len == 1, req, params);
        }

        /// `rest` is the path after the leading '/'; `at_end` distinguishes
        /// "/" (root endpoint) from "" mid-recursion bookkeeping.
        fn matchNode(
            node: *const Node,
            rest: []const u8,
            at_end: bool,
            req: *const talon.http.Request,
            params: *PathParams,
        ) ?*const Endpoint {
            if (at_end) return selectEntry(node, req);

            const slash = std.mem.indexOfScalar(u8, rest, '/');
            const seg = if (slash) |i| rest[0..i] else rest;
            const tail = if (slash) |i| rest[i + 1 ..] else rest[rest.len..];
            const tail_end = slash == null;

            if (node.findStatic(seg)) |child| {
                if (matchNode(child, tail, tail_end, req, params)) |ep| return ep;
            }
            if (node.param_child) |child| {
                if (seg.len > 0 and params.len < context_mod.max_path_params) {
                    params.append(child.capture, seg);
                    if (matchNode(child, tail, tail_end, req, params)) |ep| return ep;
                    params.len -= 1; // backtrack
                }
            }
            if (node.wildcard_child) |child| {
                if (params.len < context_mod.max_path_params) {
                    params.append(child.capture, rest);
                    if (selectEntry(child, req)) |ep| return ep;
                    params.len -= 1;
                }
            }
            return null;
        }

        fn selectEntry(node: *const Node, req: *const talon.http.Request) ?*const Endpoint {
            for (node.entries.items) |e| {
                if (e.guard) |g| {
                    if (!g(req)) continue;
                }
                return e.endpoint;
            }
            return null;
        }

        /// Methods that would match `path`: powers automatic 405 + Allow.
        pub fn allowedMethods(
            self: *const Self,
            path: []const u8,
            req: *const talon.http.Request,
        ) MethodSet {
            var set: MethodSet = .{};
            inline for (@typeInfo(talon.http.Method).@"enum".fields) |f| {
                const m: talon.http.Method = @enumFromInt(f.value);
                if (m != .other) {
                    var scratch: PathParams = .{};
                    if (self.match(m, path, req, &scratch) != null) set.insert(m);
                }
            }
            return set;
        }
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const TestState = struct { hits: u32 = 0 };
const Ctx = context_mod.Context(TestState);

fn h(ctx: *Ctx) anyerror!void {
    ctx.state.hits += 1;
}

/// Minimal fake request for guard-path unit tests; only `head` matters.
fn testRequest(head: talon.http.codec.request_parser.Head) talon.http.Request {
    return .{
        .head = head,
        .arena = std.testing.failing_allocator,
        .body = undefined, // never touched by match/guards in these tests
        .upgrade = undefined, // ditto
    };
}

fn emptyHead() talon.http.codec.request_parser.Head {
    return .{
        .method = .GET,
        .method_raw = "GET",
        .target = "/",
        .version = .@"HTTP/1.1",
        .headers = &.{},
        .host = null,
        .content_length = null,
        .transfer_chunked = false,
        .keep_alive = true,
        .expect_continue = false,
    };
}

fn expectMatch(
    router: *const Router(TestState),
    method: talon.http.Method,
    path: []const u8,
    expected_name: []const u8,
) !void {
    const req = testRequest(emptyHead());
    var params: PathParams = .{};
    const ep = router.match(method, path, &req, &params) orelse return error.TestExpectedMatch;
    try std.testing.expectEqualStrings(expected_name, ep.metadata.name);
}

fn expectNoMatch(router: *const Router(TestState), method: talon.http.Method, path: []const u8) !void {
    const req = testRequest(emptyHead());
    var params: PathParams = .{};
    try std.testing.expectEqual(null, router.match(method, path, &req, &params));
}

test "router: static routes, root, and method separation" {
    var r = Router(TestState).init(std.testing.allocator);
    defer r.deinit();

    try r.add(.GET, "/", h, .{ .name = "root" });
    try r.add(.GET, "/users", h, .{ .name = "users" });
    try r.add(.GET, "/users/all", h, .{ .name = "users-all" });
    try r.add(.POST, "/users", h, .{ .name = "create" });

    try expectMatch(&r, .GET, "/", "root");
    try expectMatch(&r, .GET, "/users", "users");
    try expectMatch(&r, .GET, "/users/all", "users-all");
    try expectMatch(&r, .POST, "/users", "create");
    try expectNoMatch(&r, .DELETE, "/users");
    try expectNoMatch(&r, .GET, "/nope");
    try expectNoMatch(&r, .GET, "/users/all/deeper");
}

test "router: param capture borrows the path buffer" {
    var r = Router(TestState).init(std.testing.allocator);
    defer r.deinit();

    try r.add(.GET, "/users/:id/posts/:post_id", h, .{ .name = "post" });

    const req = testRequest(emptyHead());
    var params: PathParams = .{};
    const path = "/users/42/posts/7";
    const ep = r.match(.GET, path, &req, &params) orelse return error.TestExpectedMatch;
    try std.testing.expectEqualStrings("post", ep.metadata.name);
    try std.testing.expectEqualStrings("42", params.get("id").?);
    try std.testing.expectEqualStrings("7", params.get("post_id").?);
    // Zero-copy: captured slices point into the path buffer.
    try std.testing.expectEqual(@intFromPtr(path.ptr + 7), @intFromPtr(params.get("id").?.ptr));
}

test "router: static beats param, with backtracking" {
    var r = Router(TestState).init(std.testing.allocator);
    defer r.deinit();

    try r.add(.GET, "/users/new", h, .{ .name = "new" });
    try r.add(.GET, "/users/:id", h, .{ .name = "by-id" });
    // Backtracking: /users/new/x fails in the static subtree, succeeds via :id.
    try r.add(.GET, "/users/:id/x", h, .{ .name = "by-id-x" });

    try expectMatch(&r, .GET, "/users/new", "new");
    try expectMatch(&r, .GET, "/users/42", "by-id");
    try expectMatch(&r, .GET, "/users/new/x", "by-id-x");

    const req = testRequest(emptyHead());
    var params: PathParams = .{};
    _ = r.match(.GET, "/users/new/x", &req, &params).?;
    // Backtracked param capture must be present exactly once.
    try std.testing.expectEqual(1, params.len);
    try std.testing.expectEqualStrings("new", params.get("id").?);
}

test "router: wildcard captures the remainder" {
    var r = Router(TestState).init(std.testing.allocator);
    defer r.deinit();

    try r.add(.GET, "/static/*path", h, .{ .name = "static" });

    const req = testRequest(emptyHead());
    var params: PathParams = .{};
    const ep = r.match(.GET, "/static/css/site.css", &req, &params) orelse
        return error.TestExpectedMatch;
    try std.testing.expectEqualStrings("static", ep.metadata.name);
    try std.testing.expectEqualStrings("css/site.css", params.get("path").?);
}

test "router: param requires a non-empty segment" {
    var r = Router(TestState).init(std.testing.allocator);
    defer r.deinit();

    try r.add(.GET, "/users/:id", h, .{ .name = "by-id" });
    try expectNoMatch(&r, .GET, "/users/");
}

test "router: registration grammar and conflicts" {
    var r = Router(TestState).init(std.testing.allocator);
    defer r.deinit();

    try std.testing.expectError(error.MalformedPath, r.add(.GET, "no-slash", h, .{}));
    try std.testing.expectError(error.MalformedPath, r.add(.GET, "/a/:", h, .{}));
    try std.testing.expectError(error.MalformedPath, r.add(.GET, "/a/*rest/b", h, .{}));

    try r.add(.GET, "/users/:id", h, .{ .name = "a" });
    // Same path, same method, no guard → conflict.
    try std.testing.expectError(error.RouteConflict, r.add(.GET, "/users/:id", h, .{}));
    // Different param name at the same position → ambiguous → conflict.
    try std.testing.expectError(error.RouteConflict, r.add(.GET, "/users/:uid/x", h, .{}));
}

test "router: nest mounts a subtree; sub-root maps to the prefix" {
    var users = Router(TestState).init(std.testing.allocator);
    defer users.deinit();
    try users.add(.GET, "/:id", h, .{ .name = "get-user" });
    try users.add(.POST, "/", h, .{ .name = "create-user" });

    var app = Router(TestState).init(std.testing.allocator);
    defer app.deinit();
    try app.add(.GET, "/health", h, .{ .name = "health" });
    try app.nest("/api/v1/users", &users);

    try expectMatch(&app, .GET, "/api/v1/users/42", "get-user");
    try expectMatch(&app, .POST, "/api/v1/users", "create-user");
    try expectMatch(&app, .GET, "/health", "health");
    // Source router emptied by move semantics.
    try expectNoMatch(&users, .GET, "/:id");
}

test "router: merge combines flat, conflicts error" {
    var a = Router(TestState).init(std.testing.allocator);
    defer a.deinit();
    try a.add(.GET, "/a", h, .{ .name = "a" });

    var b = Router(TestState).init(std.testing.allocator);
    defer b.deinit();
    try b.add(.GET, "/b", h, .{ .name = "b" });

    try a.merge(&b);
    try expectMatch(&a, .GET, "/a", "a");
    try expectMatch(&a, .GET, "/b", "b");

    var c = Router(TestState).init(std.testing.allocator);
    defer c.deinit();
    try c.add(.GET, "/a", h, .{ .name = "dup" });
    try std.testing.expectError(error.RouteConflict, a.merge(&c));
}

test "router: guard dispatch — first passing guard wins, miss continues" {
    var r = Router(TestState).init(std.testing.allocator);
    defer r.deinit();

    try r.add(.GET, "/admin", h, .{
        .name = "admin-host",
        .guard = endpoint_mod.hostIs("admin.example.com"),
    });
    try r.add(.GET, "/admin", h, .{ .name = "admin-public" });

    var head = emptyHead();
    head.host = "admin.example.com";
    const admin_req = testRequest(head);
    var params: PathParams = .{};
    const ep = r.match(.GET, "/admin", &admin_req, &params).?;
    try std.testing.expectEqualStrings("admin-host", ep.metadata.name);

    // Other host: the guarded entry is skipped, guardless one serves.
    const public_req = testRequest(emptyHead());
    const ep2 = r.match(.GET, "/admin", &public_req, &params).?;
    try std.testing.expectEqualStrings("admin-public", ep2.metadata.name);
}

test "router: guard miss with no fallback entry continues to no-match" {
    var r = Router(TestState).init(std.testing.allocator);
    defer r.deinit();

    try r.add(.GET, "/admin", h, .{
        .name = "admin-host",
        .guard = endpoint_mod.hostIs("admin.example.com"),
    });
    try expectNoMatch(&r, .GET, "/admin");
}

test "router: allowedMethods powers 405" {
    var r = Router(TestState).init(std.testing.allocator);
    defer r.deinit();

    try r.add(.GET, "/users", h, .{});
    try r.add(.POST, "/users", h, .{});

    const req = testRequest(emptyHead());
    const set = r.allowedMethods("/users", &req);
    try std.testing.expect(set.contains(.GET));
    try std.testing.expect(set.contains(.POST));
    try std.testing.expect(!set.contains(.DELETE));
    try std.testing.expectEqual(2, set.count());

    const none = r.allowedMethods("/nope", &req);
    try std.testing.expectEqual(0, none.count());
}

test "router: metadata flows through registration" {
    var r = Router(TestState).init(std.testing.allocator);
    defer r.deinit();

    try r.add(.GET, "/admin/users", h, .{
        .name = "list",
        .auth = .{ .role = "admin" },
        .rate_limit = .{ .per_second = 10 },
    });

    const req = testRequest(emptyHead());
    var params: PathParams = .{};
    const ep = r.match(.GET, "/admin/users", &req, &params).?;
    try std.testing.expectEqualStrings("admin", ep.metadata.auth.?.role);
    try std.testing.expectEqual(10, ep.metadata.rate_limit.?.per_second);
}
