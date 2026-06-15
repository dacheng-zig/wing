# wing 使用指南

> 适用版本：wing M2｜Zig 0.16.0
> 读者：用 wing 写 Web 服务的应用开发者
> 想了解框架内部机制和扩展开发，见 `docs/developer-guide.md`

wing 是一个 Zig Web 框架，对标 ASP.NET Core / axum：你写带类型签名的 handler，框架在编译期把参数绑定、响应转换全部展开好，运行时零反射、稳态请求零堆分配。

本指南从安装开始，逐步覆盖路由、提取参数、返回响应、共享状态、中间件、错误处理、静态文件和测试。每节都配可运行的示例。

---

## 1. 安装与第一个服务

### 1.1 添加依赖

wing 依赖 talon 引擎（talon 又依赖 zio 运行时）。在你项目的 `build.zig.zon` 里声明依赖（开发期可用本地 path）：

```zig
.{
    .name = .my_app,
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .wing = .{ .path = "../wing" }, // 或 talon 发布后用 url + hash
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

在 `build.zig` 里接入模块。启动代码会直接用到 `zio`（Runtime）和 `talon`（TcpListener/Server），所以三个 module 都要 import 给可执行文件。取法与 wing 自己的 `build.zig` 一致——经 wing 依赖传递拿到 talon，再经 talon 拿到 zio：

```zig
const wing_dep = b.dependency("wing", .{ .target = target, .optimize = optimize });
const wing_mod = wing_dep.module("wing");
// 经依赖链取出 talon / zio module（与 wing/build.zig 同款写法）
const talon_dep = wing_dep.builder.dependency("talon", .{ .target = target, .optimize = optimize });
const talon_mod = talon_dep.module("talon");
const zio_mod = talon_dep.builder.dependency("zio", .{ .target = target, .optimize = optimize }).module("zio");

const exe = b.addExecutable(.{
    .name = "my_app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wing", .module = wing_mod },
            .{ .name = "talon", .module = talon_mod },
            .{ .name = "zio", .module = zio_mod },
        },
    }),
});
```

> 当前 wing 与 talon 处于双仓本地联调阶段（`build.zig.zon` 用 `path`）。talon 发布 tagged release 后改为 url + hash 精确 pin。最稳妥的参照是仓库根的 `build.zig`——它就是上面这套写法的完整可跑版本。

### 1.2 Hello, wing

一个最小服务需要四样东西：**State**（共享状态）、**handler**、**Router**、**App + 启动**。

```zig
const std = @import("std");
const zio = @import("zio");
const talon = @import("talon");
const wing = @import("wing");

// 1. 状态：显式 struct，无 DI 容器。先放个空的。
const State = struct {};
const Ctx = wing.Context(State);

// 2. handler：第一个参数永远是 *Ctx；返回 []const u8 → text/plain 响应
fn hello(ctx: *Ctx) anyerror![]const u8 {
    _ = ctx;
    return "hello from wing\n";
}

// 3. App：Router + 标准中间件链
const App = wing.DefaultApp(State);

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    var router = wing.Router(State).init(init.gpa);
    defer router.deinit();
    try router.get("/", hello);

    var state: State = .{};
    var app = App.init(&router, &state);

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var listener = try talon.TcpListener.listen(addr, .{});
    var server = try talon.http.Server(App).init(init.gpa, &app, .{});
    defer server.deinit();

    std.log.info("listening on http://{f}", .{addr});
    try server.serve(&listener);
}
```

```bash
curl http://127.0.0.1:8080/
# hello from wing
```

> `DefaultApp(State)` 是开箱即用的标准链：`logger → recover → route_match → cors`。需要自定义链（比如加 `request_id`）见 §6。

仓库自带完整 demo，可直接跑：

```bash
zig build run-demo
# 另开终端：
curl http://127.0.0.1:8080/
curl http://127.0.0.1:8080/api/v1/users/42
```

---

## 2. 路由

`Router(State)` 用前缀树管理路由，按 HTTP method 分开。

### 2.1 注册方法

```zig
try router.get("/users", listUsers);
try router.post("/users", createUser);
try router.put("/users/:id", updateUser);
try router.delete("/users/:id", deleteUser);
try router.patch("/users/:id", patchUser);

// 带 metadata / guard 的完整形式：
try router.add(.GET, "/admin", adminPanel, .{ .name = "admin" });
```

### 2.2 路径参数

- `:name` —— 参数段，匹配单个路径段
- `*name` —— 通配段，必须是最后一段，捕获剩余整段路径

```zig
try router.get("/users/:id", getUser);           // /users/42 → id="42"
try router.get("/users/:id/posts/:post_id", ...); // 多个参数
try router.get("/assets/*path", serveAsset);     // /assets/css/site.css → path="css/site.css"
```

匹配优先级：**静态 > 参数 > 通配**，且带回溯。所以 `/users/new` 和 `/users/:id` 可以共存——`/users/new` 命中静态路由，`/users/42` 命中参数路由。

参数值的读取见 §3.1（用 `wing.Path` 提取器）。

### 2.3 自动行为

- **405 Method Not Allowed**：路径存在但 method 不匹配时，自动返回 405 + `Allow` 头。
- **HEAD**：自动由对应的 GET 路由处理（talon 抑制 body）。
- **404 / fallback**：未匹配时走你设的 fallback，没设则返回默认 404。

```zig
fn notFound(ctx: *Ctx) anyerror!void {
    try ctx.respond("no such route\n", .{ .status = .not_found });
}
router.fallback(notFound);
```

### 2.4 Router 组合：nest 与 merge

把路由拆成多个 Router 再组合，便于模块化。组合发生在启动期，**是移动语义**：被并入的源 Router 会被清空。

```zig
fn buildRouter(gpa: std.mem.Allocator) !wing.Router(State) {
    // 子路由，挂到前缀下（nest）
    var users = wing.Router(State).init(gpa);
    errdefer users.deinit();
    try users.get("/:id", getUser);   // 最终 = /api/v1/users/:id
    try users.get("/", listUsers);    // 最终 = /api/v1/users
    try users.post("/", createUser);

    // 平级路由（merge）
    var ops = wing.Router(State).init(gpa);
    errdefer ops.deinit();
    try ops.get("/health", health);

    var root = wing.Router(State).init(gpa);
    errdefer root.deinit();
    try root.get("/", home);
    try root.nest("/api/v1/users", &users); // 前缀挂载子树
    try root.merge(&ops);                    // 根部平级合并，冲突报错
    root.fallback(notFound);
    return root;
}
```

- `nest(prefix, &other)`：把 `other` 整棵树挂到 `prefix` 下（子路由的 `/` 映射到前缀本身）。
- `merge(&other)`：把 `other` 平级并入根部；路径冲突返回 `error.RouteConflict`。

> 组合后源 Router 已空，但你仍应保留它的 `deinit`（用 `errdefer` 防注册中途出错泄漏）。

---

## 3. 提取请求数据

handler 签名是 `fn(*Ctx, ...提取器) !返回类型`。提取器参数由框架在编译期识别并填充。三类：路径参数、查询参数、请求体。

### 3.1 路径参数：`wing.Path(T)`

按字段名把路由捕获的 `:param` 绑定到结构体：

```zig
fn getUser(
    ctx: *Ctx,
    path: wing.Path(struct { id: u64 }),
) anyerror!wing.Json(User) {
    _ = ctx;
    return .{ .value = .{ .id = path.value.id, .name = "ada" } };
}
// 路由：try router.get("/users/:id", getUser);
```

字段类型支持：整数、浮点、bool、enum、`[]const u8`、以及它们的 optional。解析失败 → 400。

### 3.2 查询参数：`wing.Query(T)`

```zig
const UserQuery = struct {
    page: u32 = 1,      // 有默认值 → URL 里可省略
    per_page: u32 = 20,
    q: ?[]const u8,     // optional → 省略时为 null
};

fn listUsers(ctx: *Ctx, q: wing.Query(UserQuery)) anyerror![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "page={d} q={s}\n", .{
        q.value.page, q.value.q orelse "<none>",
    });
}
```

```bash
curl 'http://127.0.0.1:8080/users?page=2&q=zig%20web'
# page=2 q=zig web
```

规则：
- 有默认值的字段 → 可选；optional 字段 → 省略时 null；两者都不是 → **必填**，缺失返回 400。
- 自动 URL 解码（`%20` → 空格，`+` → 空格）。
- 未知 query key 被忽略（前向兼容）。

### 3.3 请求体：`wing.Json(T)`

`wing.Json(T)` 作为参数时消费并解析 JSON 请求体。**它必须是 handler 的最后一个参数**（body 提取器每 handler 至多一个且居末，否则编译报错）。

```zig
const CreateUserReq = struct { name: []const u8 };

fn createUser(
    ctx: *Ctx,
    db: *Db,                       // 状态投影，见 §4
    body: wing.Json(CreateUserReq), // body 提取器，必须居末
) anyerror!wing.Created(User) {
    const user = db.createUser(body.value.name);
    return .{
        .value = user,
        .location = try std.fmt.allocPrint(ctx.arena, "/api/v1/users/{d}", .{user.id}),
    };
}
```

```bash
curl -X POST http://127.0.0.1:8080/api/v1/users -d '{"name":"grace"}'
# {"id":1,"name":"grace"}   （201 Created，带 Location 头）
```

JSON 解析失败 → 400（经 recover 中间件映射）。

> 内存提示：解析后的数据存活在请求 arena（`ctx.arena`），请求结束自动回收。需要更长生命周期请自行拷贝到你的 State。

---

## 4. 共享状态

wing 不用 DI 容器，用显式 `State` struct。你定义一个聚合所有依赖的结构，App 持有它的指针，每个请求通过 `ctx.state` 访问。

```zig
const Db = struct {
    next_id: u64 = 1,
    fn createUser(self: *Db, name: []const u8) User {
        const id = self.next_id;
        self.next_id += 1;
        return .{ .id = id, .name = name };
    }
};
const Config = struct { greeting: []const u8 = "hi\n" };

const State = struct { db: Db, cfg: Config };
```

### 4.1 子状态投影（推荐）

handler 直接声明 `*某字段类型` 参数，框架在编译期按类型唯一匹配，投影出对应字段：

```zig
fn home(ctx: *Ctx, cfg: *Config) anyerror![]const u8 {
    _ = ctx;
    return cfg.greeting; // cfg 自动指向 &state.cfg
}
```

> **约束**：投影按**类型**匹配。如果 State 里有两个相同类型的字段（比如两个 `u32`），投影无法消歧，会编译报错（Zig 反射拿不到参数名）。解决办法：把同类型字段各包一层不同的 struct（如 `struct { Cache }` vs `struct { SessionStore }`），或直接用 `ctx.state.xxx` 访问。

### 4.2 直接访问完整状态

```zig
fn handler(ctx: *Ctx) anyerror![]const u8 {
    const greeting = ctx.state.cfg.greeting;
    ctx.state.db.next_id += 1;
    return greeting;
}
```

> 并发提示：默认所有请求共享同一个 `*State`（读多写少天然无争用）。如果你在 handler 里写共享状态（如计数器），自己负责同步（如 `std.atomic`）。

---

## 5. 返回响应

handler 的返回类型决定响应。支持以下几种，其它类型会编译报错：

| 返回类型 | 响应 |
|----------|------|
| `[]const u8` / `[]u8` | 200，`text/plain; charset=utf-8` |
| `void` | handler 自己用 `ctx.respond` 出响应（忘了则兜底空响应） |
| `wing.Json(T)` | 200，JSON 序列化，`application/json` |
| `wing.Created(T)` | 201，JSON body + 可选 `Location` 头 |
| `wing.Redirect` | 重定向（默认 302 Found，可改） |
| 自定义带 `toResponse(self, ctx)` 的类型 | 你定义 |

```zig
// JSON
fn getUser(ctx: *Ctx, path: wing.Path(struct { id: u64 })) anyerror!wing.Json(User) {
    _ = ctx;
    return .{ .value = .{ .id = path.value.id, .name = "ada" } };
}

// 201 Created + Location
fn createUser(ctx: *Ctx, body: wing.Json(CreateUserReq)) anyerror!wing.Created(User) {
    return .{ .value = .{ .id = 1, .name = body.value.name }, .location = "/users/1" };
}

// 重定向
fn legacy(ctx: *Ctx) anyerror!wing.Redirect {
    _ = ctx;
    return .{ .location = "/", .status = .moved_permanently }; // 301
}

// 完全手动控制（void + ctx.respond）
fn custom(ctx: *Ctx) anyerror!void {
    try ctx.respond("custom body", .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "x-custom", .value = "1" }},
    });
}
```

> 出响应请用 `ctx.respond`（而非 `ctx.res.respond`），它会合并中间件累积的 header（如 CORS、`x-request-id`）。内置响应器都走 `ctx.respond`。

---

## 6. 中间件

中间件按链顺序执行。`wing.DefaultApp(State)` 给你标准链 `logger → recover → route_match → cors`。要自定义，用 `wing.App(State, .{...})` 显式列出：

```zig
const App = wing.App(State, .{
    wing.middleware.logger,
    wing.middleware.recover,
    wing.middleware.request_id, // 加上请求 id
    wing.middleware.route_match, // 提供 RouteMatched 能力
    wing.middleware.cors,        // 依赖 RouteMatched，必须排在 route_match 之后
});
```

> **顺序约束是编译期保障的**：`cors` 需要 `route_match` 先跑（它要读路由 metadata）。如果你把顺序写反，编译会直接报错，不会留到运行时。`execute` 终端由 App 自动追加，无需手写。

内置中间件：

| 中间件 | 作用 |
|--------|------|
| `logger` | 记录 method、路径、耗时 |
| `recover` | 捕获 handler 错误 → 对应状态码（见 §7） |
| `request_id` | 给请求分配唯一 id：`ctx.request_id` + `x-request-id` 响应头 |
| `route_match` | 路由匹配（必需）；自动处理 405 / HEAD / fallback |
| `cors` | 按每路由 CORS 策略处理预检和简单请求 |

### 6.1 CORS（按路由配置）

CORS 是“两阶段路由”的样板：策略作为 metadata 挂在路由上，`cors` 中间件读取它。

```zig
try router.add(.GET, "/api/data", getData, .{
    .cors = .{ .allow_origin = "https://app.example.com" },
});
```

带 `Origin` 头的请求会收到 `Access-Control-Allow-Origin`；`OPTIONS` 预检会被 `cors` 自动应答（204 + CORS 头）。`CorsPolicy` 还可配 `allow_methods`、`allow_headers`、`max_age_seconds`（有合理默认值）。

### 6.2 自定义错误映射

```zig
fn myErrorStatus(err: anyerror) talon.http.Status {
    return switch (err) {
        error.RateLimited => .too_many_requests,
        else => wing.middleware.defaultErrorStatus(err),
    };
}
const App = wing.App(State, .{
    wing.middleware.logger,
    wing.middleware.recoverWith(myErrorStatus),
    wing.middleware.route_match,
    wing.middleware.cors,
});
```

---

## 7. 错误处理

handler 返回 `!T`，抛出的错误由 `recover` 中间件映射成状态码。默认映射：

| 错误 | 状态码 |
|------|--------|
| 提取错误（`MissingQueryParam`/`InvalidJsonBody`/...） | 400 Bad Request |
| `error.NotFound` | 404 |
| `error.Unauthorized` | 401 |
| `error.Forbidden` | 403 |
| 其它任意错误 | 500 Internal Server Error |

所以你可以在 handler 里直接 `return error.NotFound`，框架替你出 404：

```zig
fn getUser(ctx: *Ctx, path: wing.Path(struct { id: u64 })) anyerror!wing.Json(User) {
    const user = ctx.state.db.find(path.value.id) orelse return error.NotFound;
    return .{ .value = user };
}
```

需要自定义错误→状态码，用 `recoverWith`（§6.2）。

---

## 8. 静态文件

`wing.static(State, root_dir)` 返回一个 handler，挂到通配路由上。自带路径穿越防御（拒绝 `..`、绝对路径、NUL）。

```zig
try router.get("/assets/*path", wing.static(State, "www"));
```

```bash
curl http://127.0.0.1:8080/assets/css/site.css  # 读 ./www/css/site.css
curl http://127.0.0.1:8080/assets/../secret      # 404，被穿越防御拦下
```

根据扩展名自动设 `Content-Type`（`.html`/`.css`/`.js`/`.json`/`.png`/`.svg`/...）。

> 当前用读文件实现；talon 提供 sendFile 后会切换为零拷贝。大文件场景请留意这一点。

---

## 9. 路由级元数据与 Guard

### 9.1 Guard：method/path 之外的路由谓词

Guard 在匹配阶段执行，返回 false 时继续匹配（如同该路由不存在）。可按 host、header 分流：

```zig
// 同一路径，按 host 分流：admin.example.com 命中第一个，其它命中第二个
try router.add(.GET, "/admin", adminPanel, .{ .guard = wing.hostIs("admin.example.com") });
try router.add(.GET, "/admin", publicPage, .{}); // 无 guard，兜底
```

内置 guard 工厂：`wing.hostIs(host)`、`wing.headerIs(name, value)`。

### 9.2 元数据

`add` 的第四个参数携带路由元数据：`name`、`cors`、`auth`、`rate_limit`、`timeout`、`guard`。

```zig
try router.add(.GET, "/admin/users", listUsers, .{
    .name = "admin-list",
    .cors = .{ .allow_origin = "https://admin.example.com" },
    .auth = .{ .role = "admin" },
});
```

> ⚠️ **当前实现状态**：只有 `cors` 元数据有对应的中间件去消费。`auth` / `rate_limit` / `timeout` 字段**会随路由流转，但目前没有中间件强制执行它们**——标 `.auth = .{ .role = "admin" }` 不会自动拦截未授权请求。如需鉴权/限流，目前要自己写中间件读取这些 metadata（机制见开发者文档 §6.2），或在 handler 内自行校验。

---

## 10. 测试

wing 自带 `TestClient`，基于内存监听器跑全栈测试——无 socket、无端口、可并行。每个请求过一遍真实链路。

```zig
const std = @import("std");
const zio = @import("zio");
const wing = @import("wing");

const App = wing.DefaultApp(State);
const Client = wing.TestClient(App);

test "GET /users/:id returns the user as JSON" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var router = try buildRouter(std.testing.allocator);
    defer router.deinit();
    var state: State = .{ .db = .{}, .cfg = .{} };

    var tc = try Client.init(std.testing.allocator, &router, &state);
    defer tc.deinit();

    var res = try tc.get("/users/42", .{});
    defer res.deinit();

    try std.testing.expectEqual(.ok, res.status);
    try res.expectJson(User, .{ .id = 42, .name = "ada" });
}

test "POST with JSON body creates" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    // ... 同上构造 router/state/tc ...

    var res = try tc.post("/users", .{ .body = "{\"name\":\"grace\"}" });
    defer res.deinit();
    try std.testing.expectEqual(.created, res.status);
    try std.testing.expectEqualStrings("/users/1", res.header("location").?);
}
```

`TestClient` 提供 `get`/`post`/`put`/`delete`/`head`/`request(method, ...)`。`RequestOptions` 可带 `headers` 和 `body`。`TestResponse` 提供：

- `res.status` —— 状态码
- `res.body` —— 响应体
- `res.header(name)` —— 取响应头（大小写不敏感）
- `res.expectJson(T, expected)` —— 解析 body 为 JSON 并深比较
- 每个 `res` 用完 `defer res.deinit()`

> 测试必须有 live `zio.Runtime`（`TestClient` 内部用协程驱动 server 和客户端）。

运行测试：

```bash
zig build test
```

---

## 11. 完整示例

仓库 `examples/demo.zig` 是一个完整可跑的示例，覆盖本指南所有特性：Router 组合（nest/merge）、Path/Query/Json 提取、状态投影、Json/Created/Redirect/text 响应、per-route metadata、guard、内置中间件、静态文件。

```bash
zig build run-demo
```

可试的端点：

```bash
curl http://127.0.0.1:8080/                                  # 文本响应（读 Config）
curl http://127.0.0.1:8080/api/v1/users/42                   # Path 提取 + JSON
curl 'http://127.0.0.1:8080/api/v1/users?page=2&q=ada'       # Query 提取
curl -X POST http://127.0.0.1:8080/api/v1/users -d '{"name":"grace"}'  # JSON body → 201
curl -X DELETE http://127.0.0.1:8080/api/v1/users            # 405 + Allow 头
curl http://127.0.0.1:8080/legacy                            # 301 重定向
curl http://127.0.0.1:8080/assets/design/wing-architecture.md # 静态文件
```

---

## 12. 速查表

```zig
// 路由
router.get/post/put/delete/patch("/path", handler);
router.add(.GET, "/path", handler, .{ .name = "x", .cors = ..., .guard = ... });
router.nest("/prefix", &subRouter);   // 移动语义
router.merge(&otherRouter);           // 移动语义，冲突报错
router.fallback(handler);

// handler 签名： fn(*Ctx, ...提取器) !返回类型
//   提取器： wing.Path(T) / wing.Query(T) / wing.Json(T)[居末] / *StateField
//   返回：   []const u8 / void / wing.Json(T) / wing.Created(T) / wing.Redirect / 自定义 toResponse

// Context
ctx.state          // *State
ctx.arena          // 请求级 allocator
ctx.params.get(n)  // 路径参数原始切片
ctx.request_id     // 需 request_id 中间件
ctx.respond(body, .{ .status = ..., .extra_headers = ... });

// App
wing.DefaultApp(State)                  // logger→recover→route_match→cors
wing.App(State, .{ ...中间件 tuple... }) // 自定义链

// 测试
wing.TestClient(App)  // .init(gpa, &router, &state)
res.status / res.body / res.header(n) / res.expectJson(T, expected)
```
