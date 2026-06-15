# wing 开发者文档：架构设计与开发规范

> 适用版本：wing M2（2026-06）｜Zig 0.16.0｜引擎 talon M1
> 读者：参与 wing 框架本体开发、扩展中间件/提取器、或需要理解内部机制的工程师
> 配套文档：架构设计稿 `docs/design/wing-architecture.md`（设计意图）；本文以**当前源码实现**为准
> 使用方文档见 `docs/user-guide.md`

---

## 1. 它是什么

wing 是构建在 talon 引擎之上的 Web 框架，定位对标 ASP.NET Core / axum：提供路由、中间件、Context、提取器和可测试性。

一句话原则：**DX 优先但零成本**——所有“框架魔法”在 comptime 消化，运行时无反射、无查找、稳态请求零堆分配。

命名：talon（隼爪，引擎，主性能）+ wing（隼翅，框架，主 DX）。

### 三仓栈

| 仓库 | 角色 | wing 的依赖关系 |
|------|------|----------------|
| `zio` | 协程运行时（Runtime / Group / Channel / Stopwatch / Signal） | 间接依赖（经 talon 传递） |
| `talon` | 网络引擎（`Server(App)`、`Request`/`Response`、`chain`、`MemoryListener`） | 直接依赖，`build.zig.zon` path 指向 `../talon` |
| `wing` | Web 框架（本仓库） | — |

---

## 2. 架构总览

### 2.1 请求生命周期

```
talon 连接 ──► Server(App).handle(req, res)
                   │
                   ▼
          wing App.handle：构造 Context
                   │
                   ▼
      talon chain 逐层执行请求级中间件
        logger → recover → [request_id] → route_match → cors → ... → executeTerminal
                   │                          │                          │
                   │                    填充 ctx.endpoint           调用 endpoint.handler(thunk)
                   │                    (+ metadata)                      │
                   │                                                      ▼
                   │                                      comptime 绑定的提取 + 调用 handler
                   │                                                      │
                   ▼                                                      ▼
              响应经 ctx.respond 合并中间件累积的 header，再交回 talon
```

关键点：**路由 match 是中间件链中部的一环**（借鉴 ASP.NET Core 的 Endpoint Routing）。`route_match` 之后的中间件能读到“将要执行什么”（`ctx.endpoint` + metadata），从而把鉴权、CORS、限流这类横切关注点写成“读元数据的统一中间件”，而不是为每个路由组各编一条嵌套闭包链。

### 2.2 模块职责

| 文件 | 职责 | 关键导出 |
|------|------|----------|
| `src/root.zig` | 模块入口，pin talon 公开契约（设计稿 §2） | 全部 `pub` 重导出 |
| `src/router.zig` | 按 method 分树的 radix tree、`nest`/`merge` 值语义组合、`match` | `Router(State)`、`MethodSet`、`RouteError` |
| `src/endpoint.zig` | `Endpoint`/`Metadata`/`RouteOptions`、guard 工厂 | `Endpoint`、`Metadata`、`hostIs`、`headerIs` |
| `src/context.zig` | 每请求 `Context`、`PathParams`、header 累积/合并 | `Context(State)`、`PathParams` |
| `src/extract.zig` | handler 签名 comptime 绑定（`bind`）、内置提取器/响应器 | `Json`、`Created`、`Redirect`、`Query`、`Path` |
| `src/state.zig` | 子状态投影（按类型唯一匹配） | `project`、`fieldCountOfType` |
| `src/middleware.zig` | 内置请求级中间件 | `logger`、`recover`/`recoverWith`、`request_id`、`route_match`、`cors`、`static` |
| `src/app.zig` | 把 Router 适配成 talon `Server(App)` | `App(State, middlewares)`、`DefaultApp(State)` |
| `src/test_client.zig` | 基于 `MemoryListener` 的全栈进程内测试客户端 | `TestClient(App)`、`TestResponse` |

---

## 3. 核心抽象详解

### 3.1 Context — 每请求上下文

`src/context.zig:36`。`Context(State)` 是 comptime 泛型，按用户的 `State` 类型特化。由 App 适配器在栈上构造（零分配），生命周期 = 当前请求：

```zig
pub fn Context(comptime State: type) type {
    return struct {
        req: *talon.http.Request,
        res: *talon.http.Response,
        arena: std.mem.Allocator,        // talon 管理的请求级 arena，请求结束自动 reset
        state: *State,
        endpoint: ?*const Endpoint = null, // route_match 后填充
        params: PathParams = .{},          // 切片借用 URL 缓冲，零拷贝
        request_id: []const u8 = "",       // request_id 中间件填充
        extra_headers: std.ArrayList(talon.http.Header) = .empty, // 见下
        router: *const Router(State),      // route_match 需要，非用户契约面
    };
}
```

**`extra_headers` 与 `respond` 的设计取舍**：talon 只写一次响应头。但 CORS、request_id 这类中间件需要在 handler 执行后注入 header。解法是让中间件把 header 累积到 `ctx.extra_headers`，由 `ctx.respond` 在真正写响应时合并（`src/context.zig:67`）。

> ⚠️ 规范：handler 与内置响应器（`Json`/`Created`/...）都应通过 `ctx.respond` 出响应，才能带上累积 header。直接调 `ctx.res.respond` 会**绕过**累积 header（仅在明确不需要时使用，如裸 handler 测试）。

### 3.2 Router — radix tree + 值语义组合

`src/router.zig:39`。早期裁决：纯 comptime 路由收益不抵模块化注册的工程成本（树查找 ~百 ns，相对每请求至少 2 次 syscall 占比 <1%），故采用运行时 radix tree + comptime 类型化 handler 注册。

- **按 method 分树**：`trees: [method_count]Node`，每个 HTTP method 一棵树。
- **段类型**：静态段、`:param` 参数段、`*wildcard` 通配段（必须是最后一段，捕获剩余路径）。
- **优先级**：静态 > 参数 > 通配，带回溯（`/users/new` 与 `/users/:id` 可共存，`src/router.zig:471` 测试）。
- **零分配查找**：`match` 不分配，参数切片借用传入的 path 缓冲（`src/router.zig:454` 测试断言指针相等）。
- **`nest`/`merge` 是移动语义**：启动期把源 router 的树整体嫁接到目标树，源 router 被清空（可安全 deinit）。冲突是注册期 error（`RouteConflict`），绝不静默。
- **Guard**（actix 借鉴）：挂在树条目上，match 阶段执行；guard 返回 false 时**继续匹配**，如同该路由不存在。同一 path 可注册多个 guard 条目 + 至多一个无 guard 条目（无 guard 条目兜底，排在最后）。

405 自动生成：`allowedMethods`（`src/router.zig:367`）遍历所有 method 树，命中即返回 `Allow` 集合。

### 3.3 Endpoint + Metadata — 两阶段路由

`src/endpoint.zig`。这是 wing 借鉴 ASP.NET Core 的核心机制：

```zig
pub const Handler = *const fn (*anyopaque) anyerror!void; // wing 唯一的动态分发点
pub const Endpoint = struct { handler: Handler, metadata: Metadata };

pub const Metadata = struct {
    name: []const u8 = "",
    auth: ?AuthRequirement = null,   // ⚠️ 当前仅占位，无消费中间件
    rate_limit: ?RateLimit = null,   // ⚠️ 当前仅占位，无消费中间件
    cors: ?CorsPolicy = null,        // cors 中间件消费（已实现）
    timeout: ?zio.Timeout = null,    // ⚠️ timeout 中间件未实现（需引擎级 deadline）
};
```

- metadata 是注册期构造的静态数据，运行时中间件读字段无查找、零成本。
- 所有 handler 最终收敛成统一 thunk `*const fn (*anyopaque) anyerror!void`——**整个框架的动态性就这一个函数指针**，提取绑定逻辑全部 comptime 展开、零成本。

> **实现状态诚实披露**：当前唯一真正消费 metadata 的中间件是 `cors`。`auth` / `rate_limit` / `timeout` 字段已存在、随路由流转（`src/router.zig:618` 测试验证流转），但**还没有对应中间件去强制执行**。在 demo 里给 `/admin` 标 `.auth = .{ .role = "admin" }` 只是携带元数据，不会拦截请求。扩展鉴权/限流中间件正是基于此机制的标准开发任务（见 §6.2）。

### 3.4 提取器与响应转换 — comptime 绑定

`src/extract.zig:32` 的 `bind` 是框架的“编译期魔法核心”。它在 comptime 遍历 handler 的参数类型，分类并生成提取代码，再包装成统一 thunk。

**handler 契约**：第一个参数必须是 `*Context(State)`；其后是任意数量的提取器参数。

参数分三类（`classify`，`src/extract.zig:101`）：

| 类别 | 判定 | 行为 |
|------|------|------|
| `state_ptr` | `*T`，且 `State` 中恰有一个 `T` 类型字段 | 投影该字段（§3.5） |
| `parts` | 有 `fromRequestParts(ctx) !Self` decl 的 struct | 只读 head，可多个 |
| `body` | 有 `fromRequest(ctx) !Self` decl 的 struct | 消费 body，**至多一个且必须居末** |

**违例在注册点直接 `@compileError`**，且给出人话级提示（参数位置 + 原因）。例如两个 body 消费者、body 消费者不在末位、State 投影类型歧义/无匹配——都在 `bind` 的 comptime 块里报错。这是 wing 刻意要“DX 反超 axum”的地方（axum 用 trait + 泛型 impl 实现同样规则，报错出名地难读）。

**响应侧对称**（`validateReturn` / `writeResponse`，`src/extract.zig:144`）：返回类型须是以下之一，否则 `@compileError`：
- `void`：handler 自行响应（若忘记响应，thunk 兜底回空响应保连接正确）
- `[]const u8` / `[]u8`：作为 `text/plain` body
- 实现了 `toResponse(self, ctx) !void` 的 struct（`Json`/`Created`/`Redirect` 或自定义）

错误（`!T`）向上传播给 `recover` 中间件做状态码映射。

### 3.5 State 与子状态投影

`src/state.zig`。等价 axum 的 `FromRef`，但实现只是 comptime 字段遍历，**不做运行时 DI 容器**（YAGNI + 与 Zig 显式哲学相悖）。

```zig
const State = struct { db: Db, cache: Cache, cfg: Config };
// handler 参数 db: *Db  → comptime 在 State 字段中按类型唯一匹配，投影出 &state.db
```

> **设计偏差（重要）**：设计稿原计划“类型不唯一时回退到字段名匹配”。**这不可实现**——Zig 反射暴露参数类型，不暴露参数名。当前实现：类型不唯一即 `@compileError`（`src/extract.zig:106`）。消歧办法：把重复类型的字段各包一层 distinct struct，或直接读 `ctx.state`。

### 3.6 中间件模型

`src/middleware.zig`。所有中间件都对 `ctx: anytype` 泛型，一份定义服务所有 `Context(State)` 特化（comptime 版的 tower 生态效应）。

中间件形态（与 talon `chain` 契约一致）：

```zig
pub const some_mw = struct {
    pub const requires = .{RouteMatched};  // 可选：声明依赖的能力（talon chain 编译期校验顺序）
    pub const provides = .{RouteMatched};  // 可选：声明提供的能力
    pub fn run(ctx: anytype, next: anytype) anyerror!void {
        // 前置逻辑
        try next.call(ctx);
        // 后置逻辑
    }
};
```

**链顺序的编译期保障**：`route_match` 声明 `provides = .{RouteMatched}`，`cors` 声明 `requires = .{RouteMatched}`。若 chain 里 cors 排在 route_match 之前，talon 的 chain `requires` 机制会在**编译期**报错。这把“两阶段路由顺序约束”这个经典误用点变成了编译错误。

内置中间件清单（当前实现）：

| 中间件 | 作用 | 备注 |
|--------|------|------|
| `route_match` | 两阶段路由的 match 阶段；填 `ctx.endpoint`；未匹配短路到 405 / fallback / 404 | `provides RouteMatched`；HEAD 走 GET 路由；CORS 预检放行给 cors |
| `executeTerminal(State)` | 链终端（§6 execute）：调用 `ctx.endpoint.handler` | App 自动追加，无需手写 |
| `recover` / `recoverWith(mapper)` | 错误边界 → 状态码；head 已发则透传让 talon 断连 | 默认映射见 `defaultErrorStatus` |
| `logger` | 记录 method + target + 耗时（`zio.Stopwatch`） | — |
| `request_id` | 进程唯一 id → `ctx.request_id` + `x-request-id` 响应头 | 原子计数器 |
| `cors` | 读 per-route `metadata.cors`；处理预检与简单请求 | 唯一消费 metadata 的中间件 |
| `static(State, root)` | 返回一个静态文件 handler（非中间件，挂通配路由） | 路径穿越防御；当前读文件实现 |

默认错误映射（`src/middleware.zig:108`）：提取错误 → 400；`NotFound` → 404；`Unauthorized` → 401；`Forbidden` → 403；其余 → 500。

---

## 4. 性能策略

| 策略 | 机制 | 验证 |
|------|------|------|
| 零虚调用分发 | 提取器 + 中间件链全 comptime 内联，动态性收敛于路由树单个 thunk 指针 | — |
| 元数据零成本横切 | Metadata 是静态数据，中间件读字段无查找 | — |
| 路由零分配 | radix tree 查找零分配，参数借用 URL 缓冲 | `src/router.zig:454`（指针相等断言） |
| 请求级零堆分配 | 全部临时分配走 talon 请求 arena，请求结束 reset；talon arena retain_capacity 复用 | `tests/zero_alloc_test.zig`（counting allocator） |

**零分配验收口径**：`tests/zero_alloc_test.zig` 用计数 allocator 包住 talon server gpa，单 keep-alive 连接先 warmup（arena 扩容、缓冲池预热），之后每个请求的 server gpa 分配计数必须保持平坦。这是 M2 验收项。

---

## 5. 与 talon 的依赖契约

wing 只消费 talon 的 5 项公开契约（`src/root.zig:53` 用测试 pin 住）：

1. `talon.http.Server(App)` comptime 泛型——wing 的 App 注入
2. `Request` / `Response` / `BodyReader` 类型
3. `req.hijack()`（WebSocket 生态包用，未进核心）
4. feature 查询（如 TLS 信息）
5. `chain` 组合器——wing 请求级中间件链直接复用

工程约束：开发期 `build.zig.zon` 用 `path = "../talon"` 本地联调；talon 发布 tagged release 后切换为 url + hash 精确 pin。wing 不依赖 talon 内部符号。

---

## 6. 开发规范

### 6.1 通用约束（继承仓库全局规则）

- **代码资产 English First**：标识符、文件名、注释中的技术说明、commit message 用英文。
- **注释只写 why/constraint/trap**，不复述代码；过时注释同步删除。
- **手术式改动**：单次变更只解决当前目标，不顺手重构无关区域。
- **设计偏差必须落注释**：实现与设计稿不一致时，在代码注释里写明原因（现有例子：`state.zig:5` 的字段名匹配偏差、`middleware.zig:10` 的 timeout/compress 推迟）。

### 6.2 扩展点开发指引

**新增提取器**：定义一个带 `fromRequestParts(ctx) !Self`（只读 head）或 `fromRequest(ctx) !Self`（消费 body）的 struct 即可，`bind` 会自动识别。约束：body 提取器每 handler 至多一个且必须居末。参考 `Query`（`src/extract.zig:254`）/ `Json`（`src/extract.zig:186`）。

**新增响应器**：定义带 `pub fn toResponse(self, ctx) !void` 的 struct，通过 `ctx.respond` 出响应（带上累积 header）。参考 `Created`（`src/extract.zig:212`）。

**新增 metadata 驱动中间件**（如 auth / rate_limit）：
1. 若读 metadata，中间件加 `pub const requires = .{RouteMatched};` 确保排在 route_match 之后（编译期校验）。
2. `run` 里读 `ctx.endpoint.?.metadata.<field>`，按字段决策。
3. 加进 App 的中间件 tuple，位置在 `route_match` 之后。
4. 这正是当前 `auth`/`rate_limit` metadata 占位等待的实现——它们的 struct 已在 `endpoint.zig` 定义好。

**新增 guard**：写一个返回 `*const fn (*const talon.http.Request) bool` 的 comptime 工厂，参考 `hostIs` / `headerIs`（`src/endpoint.zig:72`）。

### 6.3 质量门禁（交付前必过）

按适用性顺序执行，禁止只挑最省事的：

```bash
zig build            # 1. 构建（含 demo），不过则后续无意义
zig build test       # 2. 全部测试（unit + integration + zero-alloc，36 测试）
```

- 行为变更必须有 TestClient 集成测试覆盖（见 §7）。
- 触及 comptime 绑定逻辑（`extract.zig`/`state.zig`）时，要验证错误路径的 `@compileError` 文案仍是人话级。
- 声称“已验证”必须附命令 + 输出摘要。

---

## 7. 测试方法

`src/test_client.zig`。`TestClient` 基于 talon `MemoryListener`，**无 socket、无端口、可并行**，每个请求过一遍真实全栈链路（parser → 中间件 → 路由 → 提取器 → 响应编码）。

测试结构（参考 `tests/integration_test.zig`）：

```zig
const TestApp = wing.App(State, .{
    wing.middleware.logger,    wing.middleware.recover,
    wing.middleware.request_id, wing.middleware.route_match,
    wing.middleware.cors,
});
const Client = wing.TestClient(TestApp);

test "..." {
    const rt = try zio.Runtime.init(std.testing.allocator, .{}); // 必须有 live runtime
    defer rt.deinit();

    var router = try buildRouter(std.testing.allocator);
    defer router.deinit();
    var state: State = .{ ... };

    var tc = try Client.init(std.testing.allocator, &router, &state);
    defer tc.deinit();

    var res = try tc.get("/api/v1/users/42", .{});
    defer res.deinit();
    try std.testing.expectEqual(.ok, res.status);
    try res.expectJson(User, .{ .id = 42, .name = "ada" });
}
```

要点：
- 测试需要 live `zio.Runtime`——`TestClient` 内部用 `zio.Group.spawn` 起 server 协程，客户端请求也在 zio task 上驱动，故测试主线程可在 runtime 外调用。
- `TestResponse` 提供 `.status`、`.header(name)`、`.body`、`.expectJson(T, expected)`；每个 `res` 需 `defer res.deinit()`（持有 gpa 拷贝）。

---

## 8. 实现状态与路线图

### 已实现（M2）

Router（nest/merge/guard）、Endpoint metadata 两阶段路由、提取器（Path/Query/Json + state 投影）、响应器（Json/Created/Redirect/text/void）、内置中间件（logger/recover/request_id/route_match/cors/static）、TestClient、零分配验收。

### 未实现 / 推迟（设计稿提及但当前缺）

| 项 | 状态 | 原因（见代码注释） |
|----|------|-------------------|
| `auth` / `rate_limit` 中间件 | metadata 占位已就绪，无消费中间件 | 标准扩展任务（§6.2） |
| `timeout` 中间件 | 推迟 | 需引擎级 deadline 原语才能 race-free（`middleware.zig:10`） |
| `compress`（gzip） | 推迟到 M3 | 设计稿 §13 |
| `static` 走 talon sendFile | 当前为读文件实现 | 等 talon sendFile（`middleware.zig:213`） |
| `PerExecutor(T)` 热点状态 | 推迟到 M3 | 依赖 zio executor 亲和能力 |
| per-Router 局部 chain | 推迟 | 当前只有 App 级全局链 |
| WebSocket | 不进核心 | 作为生态包，基于 `req.hijack()` |

---

## 9. 风险与权衡

1. **comptime 重度使用**：提取器、中间件链组合放大编译错误的间接性。缓解：每个 comptime 入口先做显式签名校验，以短名 `@compileError` 给人话提示；提供 `DefaultApp` 等开箱特化；CI 跟踪编译耗时。
2. **对 talon 版本耦合**：契约面收敛为 5 项并精确 pin；talon 破坏性变更走 major。牺牲单仓原子重构便利，换取 talon 独立生态。
3. **两阶段路由顺序约束**：由 chain `requires` 机制编译期兜底。
4. **State 投影类型歧义**：无法按字段名消歧，文档与 `@compileError` 双重明示，避免误用。
