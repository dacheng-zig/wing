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
    path: wing.extract.Path(struct { id: u64 }),
) anyerror!wing.respond.Json(User) {
    _ = ctx;
    std.debug.assert(cfg.service.len > 0);
    return .{ .value = .{ .id = path.value.id, .name = "ada" } };
}

fn createUser(
    ctx: *Ctx,
    db: *Db,
    body: wing.extract.Json(CreateUserReq),
) anyerror!wing.respond.Created(User) {
    db.users_created += 1;
    const id: u64 = db.users_created;
    return .{
        .value = .{ .id = id, .name = body.value.name },
        .location = try std.fmt.allocPrint(ctx.arena, "/api/v1/users/{d}", .{id}),
    };
}

fn search(ctx: *Ctx, q: wing.extract.Query(Pagination)) anyerror![]const u8 {
    if (q.value.q) |term| {
        return std.fmt.allocPrint(ctx.arena, "page={d} q={s}", .{ q.value.page, term });
    }
    return std.fmt.allocPrint(ctx.arena, "page={d}", .{q.value.page});
}

const LoginForm = struct { user: []const u8, remember: bool = false };

fn formLogin(ctx: *Ctx, form: wing.extract.Form(LoginForm)) anyerror![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "user={s} remember={}", .{
        form.value.user,
        form.value.remember,
    });
}

const ClientInfo = struct {
    x_client_version: u32,
    user_agent: ?[]const u8,
    x_retries: u8 = 7,
};

fn headersEcho(ctx: *Ctx, h: wing.extract.Headers(ClientInfo)) anyerror![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "v={d} ua={s} r={d}", .{
        h.value.x_client_version,
        h.value.user_agent orelse "none",
        h.value.x_retries,
    });
}

fn bytesEcho(ctx: *Ctx, raw: wing.extract.Bytes) anyerror![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "len={d} body={s}", .{ raw.value.len, raw.value });
}

fn upload(ctx: *Ctx, mp: wing.extract.Multipart) anyerror![]const u8 {
    const f = mp.file("file") orelse return error.InvalidMultipartBody;
    return std.fmt.allocPrint(ctx.arena, "file={s} type={s} len={d} note={s}", .{
        f.filename.?,
        f.content_type orelse "none",
        f.data.len,
        mp.field("note") orelse "none",
    });
}

fn boom(ctx: *Ctx) anyerror!void {
    _ = ctx;
    return error.Boom;
}

fn oldPath(ctx: *Ctx) anyerror!wing.respond.Redirect {
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

// ── Cookie component handlers ────────────────────────────────────────────

fn login(ctx: *Ctx) anyerror![]const u8 {
    try ctx.setCookie(.{
        .name = "sid",
        .value = "tok123",
        .path = "/",
        .max_age = 3600,
        .http_only = true,
        .same_site = .lax,
    });
    return "ok";
}

const Prefs = struct { theme: []const u8 = "light", count: u32 = 0 };

fn prefs(ctx: *Ctx, c: wing.extract.Cookies(Prefs)) anyerror![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "theme={s} count={d}", .{ c.value.theme, c.value.count });
}

fn whoami(ctx: *Ctx) anyerror![]const u8 {
    return ctx.cookie("sid") orelse "anon";
}

fn multiCookie(ctx: *Ctx) anyerror![]const u8 {
    try ctx.setCookie(.{ .name = "sid", .value = "tok123", .http_only = true });
    try ctx.setCookie(.{ .name = "theme", .value = "dark", .path = "/" });
    return "ok";
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
    try r.post("/form-login", formLogin);
    try r.get("/client-info", headersEcho);
    try r.post("/echo-bytes", bytesEcho);
    try r.post("/upload", upload);
    try r.get("/boom", boom);
    try r.get("/old-path", oldPath);
    try r.get("/request-id", echoRequestId);
    try r.get("/login", login);
    try r.get("/prefs", prefs);
    try r.get("/whoami", whoami);
    try r.get("/multi-cookie", multiCookie);
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

    var res = try h.tc.post("/api/v1/users", .{
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = "{\"name\":\"grace\"}",
    });
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

    var res = try h.tc.post("/api/v1/users", .{
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = "not json",
    });
    defer res.deinit();
    try std.testing.expectEqual(.bad_request, res.status);
}

test "integration: Json body without json content-type maps to 415" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    // Missing content-type entirely.
    var res = try h.tc.post("/api/v1/users", .{ .body = "{\"name\":\"grace\"}" });
    defer res.deinit();
    try std.testing.expectEqual(.unsupported_media_type, res.status);

    // Wrong media type.
    var res2 = try h.tc.post("/api/v1/users", .{
        .headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        .body = "{\"name\":\"grace\"}",
    });
    defer res2.deinit();
    try std.testing.expectEqual(.unsupported_media_type, res2.status);

    // +json structured-syntax suffix is accepted (RFC 6839).
    var res3 = try h.tc.post("/api/v1/users", .{
        .headers = &.{.{ .name = "content-type", .value = "application/vnd.api+json" }},
        .body = "{\"name\":\"grace\"}",
    });
    defer res3.deinit();
    try std.testing.expectEqual(.created, res3.status);
}

test "integration: Form body extractor parses urlencoded fields" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const form = "content-type";
    const urlenc = "application/x-www-form-urlencoded";

    // Required field + explicit bool, with url decoding.
    var res = try h.tc.post("/form-login", .{
        .headers = &.{.{ .name = form, .value = urlenc }},
        .body = "user=ada%20l&remember=true",
    });
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings("user=ada l remember=true", res.body);

    // Field with a default is optional in the body.
    var res2 = try h.tc.post("/form-login", .{
        .headers = &.{.{ .name = form, .value = urlenc }},
        .body = "user=grace",
    });
    defer res2.deinit();
    try std.testing.expectEqualStrings("user=grace remember=false", res2.body);
}

test "integration: Form rejects wrong content-type with 415, missing fields with 400" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    // No / wrong content-type → UnsupportedMediaType → 415.
    var res = try h.tc.post("/form-login", .{ .body = "user=ada" });
    defer res.deinit();
    try std.testing.expectEqual(.unsupported_media_type, res.status);

    // Correct content-type but the required `user` field is absent → 400.
    var res2 = try h.tc.post("/form-login", .{
        .headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }},
        .body = "remember=true",
    });
    defer res2.deinit();
    try std.testing.expectEqual(.bad_request, res2.status);
}

test "integration: Headers extractor binds, defaults, and rejects" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    // All headers present; field-name → header-name mapping (`_` → `-`),
    // sent value overrides the field default.
    var res = try h.tc.get("/client-info", .{
        .headers = &.{
            .{ .name = "x-client-version", .value = "3" },
            .{ .name = "user-agent", .value = "wing-test" },
            .{ .name = "x-retries", .value = "9" },
        },
    });
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings("v=3 ua=wing-test r=9", res.body);

    // Optional header absent → null; defaulted header absent → default.
    var res2 = try h.tc.get("/client-info", .{
        .headers = &.{.{ .name = "x-client-version", .value = "1" }},
    });
    defer res2.deinit();
    try std.testing.expectEqualStrings("v=1 ua=none r=7", res2.body);

    // Required header missing → 400.
    var res3 = try h.tc.get("/client-info", .{});
    defer res3.deinit();
    try std.testing.expectEqual(.bad_request, res3.status);

    // Present but unparsable as u32 → 400.
    var res4 = try h.tc.get("/client-info", .{
        .headers = &.{.{ .name = "x-client-version", .value = "abc" }},
    });
    defer res4.deinit();
    try std.testing.expectEqual(.bad_request, res4.status);
}

test "integration: Bytes extractor hands the raw body to the handler" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    // No content-type requirement: any bytes pass through untouched.
    var res = try h.tc.post("/echo-bytes", .{ .body = "raw \x01 payload" });
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings("len=13 body=raw \x01 payload", res.body);

    // Empty body is valid raw input.
    var res2 = try h.tc.post("/echo-bytes", .{});
    defer res2.deinit();
    try std.testing.expectEqualStrings("len=0 body=", res2.body);
}

test "integration: Multipart extractor parses file uploads" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const body = "--BOUND\r\n" ++
        "content-disposition: form-data; name=\"note\"\r\n" ++
        "\r\n" ++
        "hi\r\n" ++
        "--BOUND\r\n" ++
        "content-disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" ++
        "content-type: text/plain\r\n" ++
        "\r\n" ++
        "hello world\r\n" ++
        "--BOUND--\r\n";
    var res = try h.tc.post("/upload", .{
        .headers = &.{.{ .name = "content-type", .value = "multipart/form-data; boundary=BOUND" }},
        .body = body,
    });
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings("file=a.txt type=text/plain len=11 note=hi", res.body);

    // Wrong media type → 415.
    var res2 = try h.tc.post("/upload", .{
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = "{}",
    });
    defer res2.deinit();
    try std.testing.expectEqual(.unsupported_media_type, res2.status);

    // Right media type, missing boundary → 400.
    var res3 = try h.tc.post("/upload", .{
        .headers = &.{.{ .name = "content-type", .value = "multipart/form-data" }},
        .body = body,
    });
    defer res3.deinit();
    try std.testing.expectEqual(.bad_request, res3.status);

    // Malformed framing (no close delimiter) → 400.
    var res4 = try h.tc.post("/upload", .{
        .headers = &.{.{ .name = "content-type", .value = "multipart/form-data; boundary=BOUND" }},
        .body = "--BOUND\r\ncontent-disposition: form-data; name=\"x\"\r\n\r\nv",
    });
    defer res4.deinit();
    try std.testing.expectEqual(.bad_request, res4.status);
}

test "integration: oversized chunked body maps to 413, within-limit parses" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var router = try buildRouter(std.testing.allocator);
    defer router.deinit();
    var state: State = .{ .db = .{}, .cfg = .{} };

    // Tiny body cap so a normal form body trips the streaming limit. Only
    // chunked bodies reach the extractor — talon rejects oversized
    // Content-Length bodies before the handler runs.
    var tc = try Client.initWithOptions(std.testing.allocator, &router, &state, .{
        .limits = .{ .max_body_size = 16 },
    });
    defer tc.deinit();

    const form = "content-type";
    const urlenc = "application/x-www-form-urlencoded";

    // Within the cap: chunked framing parses just like Content-Length (control
    // that proves chunking itself is handled, isolating the size as the cause).
    var ok = try tc.post("/form-login", .{
        .headers = &.{.{ .name = form, .value = urlenc }},
        .body = "user=ada", // 8 bytes ≤ 16
        .chunked = true,
    });
    defer ok.deinit();
    try std.testing.expectEqual(.ok, ok.status);
    try std.testing.expectEqualStrings("user=ada remember=false", ok.body);

    // Past the cap → BodyTooLarge surfaces as PayloadTooLarge → 413 (not 400).
    var res = try tc.post("/form-login", .{
        .headers = &.{.{ .name = form, .value = urlenc }},
        .body = "user=aaaaaaaaaaaaaaaaaaaaaaaaaaaa", // 33 bytes > 16
        .chunked = true,
    });
    defer res.deinit();
    try std.testing.expectEqual(.payload_too_large, res.status);
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

test "integration: setCookie emits a Set-Cookie header" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.get("/login", .{});
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    try std.testing.expectEqualStrings(
        "sid=tok123; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax",
        res.header("set-cookie").?,
    );
}

test "integration: typed Cookies extractor binds request cookies" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.get("/prefs", .{
        .headers = &.{.{ .name = "cookie", .value = "theme=dark; count=5" }},
    });
    defer res.deinit();
    try std.testing.expectEqualStrings("theme=dark count=5", res.body);

    // Missing cookies fall back to field defaults.
    var res2 = try h.tc.get("/prefs", .{});
    defer res2.deinit();
    try std.testing.expectEqualStrings("theme=light count=0", res2.body);
}

test "integration: multiple Set-Cookie headers are each observable" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.get("/multi-cookie", .{});
    defer res.deinit();
    try std.testing.expectEqualStrings("tok123", res.cookie("sid").?);
    try std.testing.expectEqualStrings("dark", res.cookie("theme").?);
    try std.testing.expectEqual(@as(?[]const u8, null), res.cookie("missing"));
}

test "integration: ctx.cookie reads a single request cookie" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    var res = try h.tc.get("/whoami", .{
        .headers = &.{.{ .name = "cookie", .value = "sid=abc; other=1" }},
    });
    defer res.deinit();
    try std.testing.expectEqualStrings("abc", res.body);

    var res2 = try h.tc.get("/whoami", .{});
    defer res2.deinit();
    try std.testing.expectEqualStrings("anon", res2.body);
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
