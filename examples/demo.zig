//! wing framework demo.
//!
//! Shows the full first-phase surface: Router composition (nest/merge),
//! typed extractors (wing.extract.* + state projection), toResponse
//! conversion (wing.respond.* / text), per-route metadata (cors, auth),
//! guards, built-in middleware, and static file serving.
//!
//! Run:  zig build run-demo
//! Try:  curl http://127.0.0.1:8080/
//!       curl http://127.0.0.1:8080/api/v1/users/42
//!       curl 'http://127.0.0.1:8080/api/v1/users?page=2&q=ada'
//!       curl -X POST http://127.0.0.1:8080/api/v1/users \
//!            -H 'content-type: application/json' -d '{"name":"grace"}'
//!       curl -X DELETE http://127.0.0.1:8080/api/v1/users   # 405 + Allow
//!       curl -F file=@build.zig -F note=hi http://127.0.0.1:8080/upload
//!       curl http://127.0.0.1:8080/assets/user-guide.md
//!       curl -i 'http://127.0.0.1:8080/theme/set?theme=light'  # Set-Cookie
//!       curl --cookie 'theme=light' http://127.0.0.1:8080/theme

const std = @import("std");
const zio = @import("zio");
const talon = @import("talon");
const wing = @import("wing");

// ── State (explicit, no DI container) ───────────────────────────────────

const Db = struct {
    next_id: u64 = 1,

    fn createUser(self: *Db, name: []const u8) User {
        const id = self.next_id;
        self.next_id += 1;
        return .{ .id = id, .name = name };
    }
};

const Config = struct { greeting: []const u8 = "hello from wing\n" };

const State = struct { db: Db, cfg: Config };
const Ctx = wing.Context(State);

// ── Models ───────────────────────────────────────────────────────────────

const User = struct { id: u64, name: []const u8 };
const CreateUserReq = struct { name: []const u8 };
const UserQuery = struct { page: u32 = 1, q: ?[]const u8 };

// ── Handlers (typed signatures, comptime-bound) ──────────────────────────

fn home(ctx: *Ctx, cfg: *Config) anyerror![]const u8 {
    _ = ctx;
    return cfg.greeting;
}

fn getUser(
    ctx: *Ctx,
    path: wing.extract.Path(struct { id: u64 }),
) anyerror!wing.respond.Json(User) {
    _ = ctx;
    return .{ .value = .{ .id = path.value.id, .name = "ada" } };
}

fn listUsers(ctx: *Ctx, q: wing.extract.Query(UserQuery)) anyerror![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "users page={d} q={s}\n", .{
        q.value.page, q.value.q orelse "<none>",
    });
}

fn createUser(
    ctx: *Ctx,
    db: *Db,
    body: wing.extract.Json(CreateUserReq),
) anyerror!wing.respond.Created(User) {
    const user = db.createUser(body.value.name);
    return .{
        .value = user,
        .location = try std.fmt.allocPrint(ctx.arena, "/api/v1/users/{d}", .{user.id}),
    };
}

fn legacy(ctx: *Ctx) anyerror!wing.respond.Redirect {
    _ = ctx;
    return .{ .location = "/", .status = .moved_permanently };
}

fn health(ctx: *Ctx) anyerror![]const u8 {
    _ = ctx;
    return "ok\n";
}

// Cookie component: write a hardened session cookie, read it back.
fn setTheme(ctx: *Ctx, q: wing.extract.Query(struct { theme: []const u8 = "dark" })) anyerror![]const u8 {
    try ctx.setCookie(.{
        .name = "theme",
        .value = q.value.theme,
        .path = "/",
        .max_age = 7 * 24 * 3600,
        .http_only = true,
        .same_site = .lax,
    });
    return "theme saved\n";
}

fn readTheme(ctx: *Ctx) anyerror![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "theme={s}\n", .{ctx.cookie("theme") orelse "<unset>"});
}

fn upload(ctx: *Ctx, mp: wing.extract.Multipart) anyerror![]const u8 {
    const f = mp.file("file") orelse return error.InvalidMultipartBody;
    return std.fmt.allocPrint(ctx.arena, "got {s} ({d} bytes), note={s}\n", .{
        f.filename.?,
        f.data.len,
        mp.field("note") orelse "<none>",
    });
}

fn adminPanel(ctx: *Ctx) anyerror![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "admin panel (request {s})\n", .{ctx.request_id});
}

fn notFound(ctx: *Ctx) anyerror!void {
    try ctx.respond("wing: no such route\n", .{ .status = .not_found });
}

// ── App assembly ─────────────────────────────────────────────────────────

const App = wing.App(State, .{
    wing.middleware.logger,
    wing.middleware.recover,
    wing.middleware.request_id,
    wing.middleware.route_match, // provides RouteMatched...
    wing.middleware.cors, // ...required here: order checked at comptime
});

fn buildRouter(gpa: std.mem.Allocator) !wing.Router(State) {
    // Sub-router, mounted under a prefix (nest).
    var users = wing.Router(State).init(gpa);
    errdefer users.deinit();
    try users.get("/:id", getUser);
    try users.get("/", listUsers);
    try users.post("/", createUser);

    // Flat-merged sibling (merge).
    var ops = wing.Router(State).init(gpa);
    errdefer ops.deinit();
    try ops.get("/health", health);
    try ops.get("/theme", readTheme);
    try ops.get("/theme/set", setTheme);

    var root = wing.Router(State).init(gpa);
    errdefer root.deinit();
    try root.get("/", home);
    try root.get("/legacy", legacy);
    try root.post("/upload", upload);
    try root.get("/assets/*path", wing.static(State, "docs"));
    // Per-route metadata: cors policy + auth requirement + guard.
    try root.add(.GET, "/admin", adminPanel, .{
        .name = "admin-panel",
        .auth = .{ .role = "admin" },
        .cors = .{ .allow_origin = "https://admin.example.com" },
        .guard = wing.hostIs("127.0.0.1:8080"),
    });
    try root.nest("/api/v1/users", &users);
    try root.merge(&ops);
    root.fallback(notFound);
    return root;
}

fn signalWatcher(server: *talon.http.Server(App)) !void {
    var sig = try zio.Signal.init(.interrupt);
    defer sig.deinit();
    try sig.wait();
    std.log.info("SIGINT received, draining...", .{});
    server.shutdown();
}

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(init.gpa, .{
        .stack_pool = .{
            .maximum_size = 8 * 1024 * 1024,
            .committed_size = 64 * 1024,
        },
    });
    defer rt.deinit();

    var router = try buildRouter(init.gpa);
    defer router.deinit();
    var state: State = .{ .db = .{}, .cfg = .{} };
    var app = App.init(&router, &state);

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var listener = try talon.TcpListener.listen(addr, .{});

    var server = try talon.http.Server(App).init(init.gpa, &app, .{});
    defer server.deinit();

    var group: zio.Group = .init;
    defer group.cancel();
    try group.spawn(signalWatcher, .{&server});

    std.log.info("wing listening on http://{f} (Ctrl+C to stop)", .{addr});
    try server.serve(&listener);
    std.log.info("bye", .{});
}
