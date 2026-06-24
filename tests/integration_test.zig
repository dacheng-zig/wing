//! Full-stack integration tests: TestClient → talon MemoryListener →
//! wing chain → routing → extractors → response encoding.

const std = @import("std");
const talon = @import("talon");
const zio = @import("zio");
const wing = @import("wing");

// ── Test application ─────────────────────────────────────────────────────

const Db = struct { users_created: u32 = 0 };
const Config = struct { service: []const u8 = "wing-test" };
const State = struct { db: Db, cfg: Config };

const Ctx = wing.Context(State);

const User = struct { id: u64, name: []const u8 };
const CreateUserReq = struct { name: []const u8 };
const Pagination = struct { page: u32 = 1, q: ?[]const u8 };

fn rawRoot(ctx: *Ctx) anyerror!void {
    try ctx.res.respond("welcome\n", .{});
}

fn getUser(
    ctx: *Ctx,
    cfg: *Config,
    path: wing.Path(struct { id: u64 }),
) anyerror!wing.Json(User) {
    _ = ctx;
    std.debug.assert(cfg.service.len > 0);
    return .{ .value = .{ .id = path.value.id, .name = "ada" } };
}

fn createUser(
    ctx: *Ctx,
    db: *Db,
    body: wing.Json(CreateUserReq),
) anyerror!wing.Created(User) {
    db.users_created += 1;
    const id: u64 = db.users_created;
    return .{
        .value = .{ .id = id, .name = body.value.name },
        .location = try std.fmt.allocPrint(ctx.arena, "/api/v1/users/{d}", .{id}),
    };
}

fn search(ctx: *Ctx, q: wing.Query(Pagination)) anyerror![]const u8 {
    if (q.value.q) |term| {
        return std.fmt.allocPrint(ctx.arena, "page={d} q={s}", .{ q.value.page, term });
    }
    return std.fmt.allocPrint(ctx.arena, "page={d}", .{q.value.page});
}

fn boom(ctx: *Ctx) anyerror!void {
    _ = ctx;
    return error.Boom;
}

fn oldPath(ctx: *Ctx) anyerror!wing.Redirect {
    _ = ctx;
    return .{ .location = "/new-path" };
}

fn echoRequestId(ctx: *Ctx) anyerror![]const u8 {
    return ctx.request_id;
}

fn adminOnly(ctx: *Ctx) anyerror![]const u8 {
    _ = ctx;
    return "admin";
}

fn publicSite(ctx: *Ctx) anyerror![]const u8 {
    _ = ctx;
    return "public";
}

fn corsData(ctx: *Ctx) anyerror![]const u8 {
    _ = ctx;
    return "cors-data";
}

fn notFoundFallback(ctx: *Ctx) anyerror!void {
    try ctx.respond("custom fallback\n", .{ .status = .not_found });
}

const TestApp = wing.App(State, .{
    wing.middleware.logger,
    wing.middleware.recover,
    wing.middleware.request_id,
    wing.middleware.route_match,
    wing.middleware.cors,
});

const Client = wing.TestClient(TestApp);

fn buildRouter(gpa: std.mem.Allocator) !wing.Router(State) {
    var users = wing.Router(State).init(gpa);
    errdefer users.deinit();
    try users.get("/:id", getUser);
    try users.post("/", createUser);

    var r = wing.Router(State).init(gpa);
    errdefer r.deinit();
    try r.get("/", rawRoot);
    try r.get("/search", search);
    try r.get("/boom", boom);
    try r.get("/old-path", oldPath);
    try r.get("/request-id", echoRequestId);
    try r.get("/assets/*path", wing.static(State, "docs"));
    try r.add(.GET, "/admin", adminOnly, .{ .guard = wing.hostIs("admin.example.com") });
    try r.add(.GET, "/admin", publicSite, .{});
    try r.add(.GET, "/cors-data", corsData, .{
        .cors = .{ .allow_origin = "https://app.example.com" },
    });
    try r.nest("/api/v1/users", &users);
    r.fallback(notFoundFallback);
    return r;
}

const Harness = struct {
    router: wing.Router(State),
    state: State,
    tc: Client,

    fn init(self: *Harness, gpa: std.mem.Allocator) !void {
        self.router = try buildRouter(gpa);
        errdefer self.router.deinit();
        self.state = .{ .db = .{}, .cfg = .{} };
        self.tc = try Client.init(gpa, &self.router, &self.state);
    }

    fn deinit(self: *Harness) void {
        self.tc.deinit();
        self.router.deinit();
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "integration: raw handler responds" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.get("/", .{});
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings("welcome\n", res.body);
}

test "integration: path param + state projection + Json response" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.get("/api/v1/users/42", .{});
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings("application/json", res.header("content-type").?);
    try res.expectJson(User, .{ .id = 42, .name = "ada" });
}

test "integration: Json body extractor + Created with location" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.post("/api/v1/users", .{ .body = "{\"name\":\"grace\"}" });
    defer res.deinit();
    try std.testing.expectEqual(.created, res.status);
    try std.testing.expectEqualStrings("/api/v1/users/1", res.header("location").?);
    try res.expectJson(User, .{ .id = 1, .name = "grace" });
    try std.testing.expectEqual(1, h.state.db.users_created);
}

test "integration: malformed Json body maps to 400 via recover" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.post("/api/v1/users", .{ .body = "not json" });
    defer res.deinit();
    try std.testing.expectEqual(.bad_request, res.status);
}

test "integration: query extractor with defaults and url decoding" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.get("/search?page=3&q=zig%20web", .{});
    defer res.deinit();
    try std.testing.expectEqualStrings("page=3 q=zig web", res.body);

    var res2 = try h.tc.get("/search", .{});
    defer res2.deinit();
    try std.testing.expectEqualStrings("page=1", res2.body);
}

test "integration: handler error becomes 500 via recover" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.get("/boom", .{});
    defer res.deinit();
    try std.testing.expectEqual(.internal_server_error, res.status);
}

test "integration: redirect responder" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.get("/old-path", .{});
    defer res.deinit();
    try std.testing.expectEqual(.found, res.status);
    try std.testing.expectEqualStrings("/new-path", res.header("location").?);
}

test "integration: request_id lands in ctx and response header" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.get("/request-id", .{});
    defer res.deinit();
    const hdr = res.header("x-request-id").?;
    try std.testing.expectEqual(16, hdr.len);
    // Body is ctx.request_id: header and context must agree.
    try std.testing.expectEqualStrings(res.body, hdr);
}

test "integration: 405 with Allow, custom fallback 404" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.delete("/api/v1/users", .{});
    defer res.deinit();
    try std.testing.expectEqual(.method_not_allowed, res.status);
    try std.testing.expectEqualStrings("POST", res.header("allow").?);

    var res2 = try h.tc.get("/definitely-missing", .{});
    defer res2.deinit();
    try std.testing.expectEqual(.not_found, res2.status);
    try std.testing.expectEqualStrings("custom fallback\n", res2.body);
}

test "integration: HEAD is served by the GET route with no body" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.head("/", .{});
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    // talon suppresses the body; content-length still reflects the entity.
    try std.testing.expectEqual(0, res.body.len);
    try std.testing.expectEqualStrings("8", res.header("content-length").?);
}

test "integration: guard routes by host header" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.get("/admin", .{
        .headers = &.{.{ .name = "host", .value = "admin.example.com" }},
    });
    defer res.deinit();
    try std.testing.expectEqualStrings("admin", res.body);

    var res2 = try h.tc.get("/admin", .{});
    defer res2.deinit();
    try std.testing.expectEqualStrings("public", res2.body);
}

test "integration: cors preflight and simple-request header" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    // Preflight: OPTIONS + ACRM for a route carrying a cors policy.
    var pre = try h.tc.request(.OPTIONS, "/cors-data", .{
        .headers = &.{
            .{ .name = "origin", .value = "https://app.example.com" },
            .{ .name = "access-control-request-method", .value = "GET" },
        },
    });
    defer pre.deinit();
    try std.testing.expectEqual(.no_content, pre.status);
    try std.testing.expectEqualStrings(
        "https://app.example.com",
        pre.header("access-control-allow-origin").?,
    );
    try std.testing.expect(pre.header("access-control-allow-methods") != null);

    // Simple request: policy header injected on the actual response.
    var res = try h.tc.get("/cors-data", .{
        .headers = &.{.{ .name = "origin", .value = "https://app.example.com" }},
    });
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings(
        "https://app.example.com",
        res.header("access-control-allow-origin").?,
    );

    // No origin → no cors header.
    var res2 = try h.tc.get("/cors-data", .{});
    defer res2.deinit();
    try std.testing.expectEqual(null, res2.header("access-control-allow-origin"));
}

test "integration: static file serving with traversal defense" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    // Serves out of the repo's own docs/ dir (cwd = package root under
    // `zig build test`).
    var res = try h.tc.get("/assets/wing-architecture.md", .{});
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "wing") != null);

    var res2 = try h.tc.get("/assets/../build.zig", .{});
    defer res2.deinit();
    try std.testing.expectEqual(.not_found, res2.status);
}
