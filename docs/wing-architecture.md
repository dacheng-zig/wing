# wing：基于 talon 的 Web 框架架构设计

> 范围：wing 框架的架构设计与实现思路

**命名**：wing（翅）与引擎 talon（隼之利爪）同属一只猛禽——爪司力量与击杀（引擎性能），翅司扬升与优雅（框架 DX）。*Claws for the kill, wings for the flight.*

> DX: developer experience 开发者体验

## 1. 目标与非目标

### 目标

- 定位 ≈ ASP.NET Core / axum：路由、中间件、Context、提取器、可测试性，依赖 talon 的公开契约
- DX 优先但零成本：comptime 反射做参数绑定与响应转换，编译期消化所有"框架魔法"，运行时无反射无查找
- 报错体验反超参照系：所有 comptime 校验给出人话级 `@compileError`（参数位置 + 原因）

### 非目标（首期）

- 运行时 DI 容器（用显式 State + comptime 投影）
- ORM、模板引擎、session 等全家桶（生态包定位，不进核心）
- 触碰 talon 连接内部（只经公开契约交互）

## 2. 与 talon 的依赖契约

wing 只消费 talon 的公开契约（talon 文档 §2，semver 边界）：

1. `Server(App)` comptime 泛型——wing 的 Router 包装为 App 注入
2. `Request` / `Response` / `BodyReader` 类型
3. `req.hijack()`（WebSocket 生态包用）
4. feature 查询（如读取 TLS 信息）
5. `chain` 组合器（权威定义在 talon 文档 §7；wing 的请求级中间件链直接复用）

工程约束：`build.zig.zon` 精确 pin talon 版本；开发期用 `zig build --fork` 本地联调两仓；wing 不依赖 `talon-core` 内部符号。

## 3. 借鉴矩阵（框架侧）

引擎侧借鉴（Kestrel/Netty/tower 等）见 talon 文档 §3。借鉴纪律同源：**抄问题清单，不抄解法结构**。

### 来自 ASP.NET Core

| 机制 | 裁决 | Zig 化形态 |
|------|------|-----------|
| Endpoint Routing（路由即中间件，产出 Endpoint+Metadata，后续中间件按元数据决策） | **采纳** | 两阶段路由：match → `ctx.endpoint`，auth/CORS/限流中间件读取 per-route 元数据（§6） |
| 中间件管线（`Func<RequestDelegate, RequestDelegate>`） | **已有更优解** | comptime chain 全内联，无委托链堆分配 |
| Minimal API 参数绑定（反射/source-gen） | **已有更优解** | comptime 提取器，等价于 source-gen 且零工具链 |
| DI 容器（`IServiceCollection`） | **拒绝** | 显式 `State` 结构 + comptime 子状态投影（§8）；运行时服务定位与 Zig 显式哲学冲突 |
| Options pattern | **简化** | 普通 config struct，comptime 默认值 |

### 来自 axum

| 机制 | 裁决 | Zig 化形态 |
|------|------|-----------|
| Router 组合（`nest`/`merge`/`fallback`） | **采纳** | 路由树值语义组合（§5） |
| `FromRequestParts` vs `FromRequest`（类型系统强制 body 消费者唯一且居末） | **采纳** | comptime 检查参数顺序与 body 消费唯一性，违例 `@compileError`（§7） |
| `IntoResponse`（返回类型 → 响应的 trait 转换） | **采纳** | comptime duck typing：`toResponse()` decl 检查（§7） |
| `State` + `FromRef`（类型安全子状态） | **采纳** | comptime 按类型/字段匹配从 App State 投影子状态（§8） |
| Handler trait 对多参数 fn 的 magic | **已有更优解** | comptime 反射天然支持，无需 trait 体操 |
| axum-test 风格测试客户端 | **采纳** | TestClient 基于 talon MemoryListener（§10） |

### 来自 actix-web

| 机制 | 裁决 | Zig 化形态 |
|------|------|-----------|
| worker-per-core + App factory（每 worker 一个 App 实例，无共享争用） | **改造为可选** | Zig 无 Send/Sync 约束，默认共享 State；提供可选 per-executor 状态副本应对真热点（§8） |
| Guard（method/path 之外的路由谓词：header、host） | **采纳** | comptime guard 函数挂在路由元数据上，match 阶段执行（§6） |
| actor model | **拒绝** | zio 协程 + Channel 已覆盖，引入 actor 是双抽象 |

## 4. Context 与 handler 契约

```zig
pub fn Context(comptime State: type) type {
    return struct {
        req: *talon.http.Request,
        res: *talon.http.Response,
        arena: std.mem.Allocator,     // 请求级 arena（talon 管理，请求结束自动回收）
        state: *State,
        endpoint: ?*const Endpoint,   // 路由 match 后填充（§6）
        params: PathParams,           // 切片借用 URL 缓冲，生命周期 = 当前请求
    };
}
```

基础 handler 签名 `fn (*Context) !void`；类型化签名见 §7。

## 5. Router 组合（axum）

```zig
var user_routes = wing.Router(State).init(gpa);
try user_routes.get("/:id", getUser);
try user_routes.post("/", createUser);

var app_router = wing.Router(State).init(gpa);
try app_router.nest("/api/v1/users", &user_routes);   // 前缀挂载，子树整体并入
try app_router.merge(&health_routes);                  // 平级合并，冲突报错
app_router.fallback(notFound);                         // 未匹配兜底
```

- **radix tree（压缩前缀树）+ comptime 类型化 handler 注册**（早期裁决：纯 comptime 路由收益不抵模块化注册的工程成本；树查找 ~百 ns，相对每请求至少 2 次 syscall 占比 <1%）
- 树节点支持：静态段、`:param` 参数段、`*` 通配段；查找零分配，参数切片借用 URL 缓冲
- 按 method 分树；405 自动生成 `Allow` header
- `nest/merge` 是树的值语义拼接，发生在启动期，与查找性能无关
- 每个 Router/group 可挂自己的请求级 chain；嵌套时外层链包裹内层链（comptime 已知的组合在注册时静态合成 thunk）

## 6. Endpoint + Metadata 两阶段路由（ASP.NET Core 核心借鉴）

**路由 match 是中间件链中部的一环，之后的中间件能看到"将要执行什么"**：

```zig
pub const Endpoint = struct {
    handler: *const fn (*anyopaque) anyerror!void,  // 统一 thunk
    metadata: Metadata,
};
pub const Metadata = struct {
    name: []const u8 = "",
    auth: ?AuthRequirement = null,      // auth 中间件读取
    rate_limit: ?RateLimit = null,      // 限流中间件读取
    cors: ?CorsPolicy = null,           // CORS 中间件读取
    timeout: ?zio.Timeout = null,       // 超时中间件读取
};

// 注册时随路由声明：
try router.get("/admin/users", listUsers, .{ .auth = .{ .role = "admin" } });

// 链形态： .{ logger, recover, wing.route_match, cors, auth, rate_limit, wing.execute }
```

- 横切关注点（鉴权/限流/CORS）从"包在 handler 外的嵌套闭包"变成"读元数据的统一中间件"——按路由差异化策略不再需要为每个 group 编一条链
- metadata 是 comptime 构造的 `*const` 静态数据，零运行时成本
- **Guard（actix）**挂在同一处：`.{ .guard = hostIs("admin.example.com") }`，match 阶段执行谓词，不命中继续匹配
- 链顺序约束（`route_match` 之后才能用读 metadata 的中间件）由 chain 的 `requires` 机制编译期校验（talon 文档 §7）

## 7. 提取器与响应转换（axum 形式化）

```zig
// 两类提取器契约（comptime duck typing）：
//   fromRequestParts(ctx) !Self        — 只读 head，可有多个
//   fromRequest(ctx) !Self             — 消费 body，至多一个且必须是最后一个参数
// 违例在注册处 @compileError，指出参数位置与原因

fn createUser(
    ctx: *Ctx,
    db: *Db,                          // State 子状态投影（§8）
    q: wing.Query(Pagination),        // fromRequestParts
    body: wing.Json(CreateUserReq),   // fromRequest — 必须居末
) !wing.Created(User) { ... }
```

- `Router.register` 在 comptime 遍历 `@typeInfo(handler).@"fn".params`，按参数类型生成提取代码（路径参数 parse、query 解码、JSON body 反序列化），全部静态展开
- 响应侧对称：返回类型实现 `toResponse(ctx)` 即可（`wing.Json(T)`、`wing.Created(T)`、`wing.Redirect`、裸 `[]const u8`、`void`）；error set → 状态码映射表可由用户 comptime 覆盖
- 所有 handler 最终包装成统一 thunk `*const fn (*anyopaque) anyerror!void` 存入路由树——动态性收敛在这一个函数指针上，绑定逻辑零成本
- axum 用 trait + 泛型 impl 体操实现这套规则，报错信息是出名的天书；comptime 版本在注册点直接给出"第 3 个参数 X 消费 body，但其后还有参数 Y"级别的人话错误——**DX 反超参照系**

## 8. State 与子状态投影（axum FromRef + actix 裁决）

```zig
const State = struct { db: Db, cache: Cache, cfg: Config };
// handler 参数 `db: *Db` → comptime 在 State 字段中按类型唯一匹配并投影；
// 类型不唯一时要求字段名匹配，仍无法消歧则 @compileError
```

- 等价 axum `FromRef`，实现只是 comptime 字段遍历；不做运行时服务容器（YAGNI + 与 Zig 显式哲学相悖）
- **actix worker-per-core 模型的裁决**：actix 每 worker 克隆 App 是为绕开 Rust 的 Send/Sync 与锁争用；Zig 无此类型约束，默认共享 `*State`（读多写少场景天然无争用）。对真热点（每请求计数器、本地缓存）提供可选 `wing.PerExecutor(T)`：按 zio executor id 索引的数组，cache line 对齐去伪共享，读自己执行器的槽位。注意 zio spawn 无亲和性意味着同一连接的多个请求可能落不同执行器——`PerExecutor` 只适合可合并的统计类状态，文档明示语义边界

## 9. 内置中间件（首期清单）

`recover`（error 边界 → 500）、`logger`、`cors`、`static`（基于 talon sendFile + 路径穿越防御）、`timeout`、`compress`（gzip）、`route_match` / `execute`（两阶段路由标准件）、`request_id`。

WebSocket 不进核心：作为 wing 生态包，基于 `req.hijack()` 实现。

## 10. TestClient（Kestrel TestServer + axum-test）

```zig
var tc = try wing.TestClient.init(gpa, &router, &state);  // 内部起 talon MemoryListener server
const res = try tc.get("/api/v1/users/42", .{});
try std.testing.expectEqual(.ok, res.status);
try res.expectJson(User, .{ .id = 42, ... });
```

- 全栈过一遍真实链路（连接中间件可选注入），无 socket、无端口冲突、可并行跑测试
- 这是 talon 把 MemoryListener 做成一等公民的直接回报（talon 文档 §5.2）

## 11. 性能策略（wing 侧）

| 策略 | 机制 |
|------|------|
| 零虚调用 handler 分发 | comptime 提取器 + 中间件链全内联，动态性收敛于路由树中单个 thunk 指针 |
| 元数据零成本横切 | Endpoint metadata 为 `*const` 静态数据，中间件读字段无查找 |
| 路由零分配 | radix tree 查找零分配，参数借用 URL 缓冲 |
| 去伪共享热点状态 | `PerExecutor(T)` cache line 对齐槽位 |
| 请求级零堆分配 | 全部临时分配走 talon 请求 arena，请求结束 reset |

验收口径：零分配经 allocator 计数验证（M2）。

## 12. 项目结构

```
wing/                              # dacheng-zig/wing
├── build.zig / build.zig.zon      # 依赖 talon（精确 pin）
├── src/
│   ├── root.zig                   # module: wing
│   ├── router.zig                 # radix tree、nest/merge/guard
│   ├── endpoint.zig               # Endpoint、Metadata
│   ├── context.zig / extract.zig  # Context、提取器、toResponse
│   ├── state.zig                  # 子状态投影、PerExecutor
│   ├── middleware/                # logger、recover、cors、static、timeout、compress...
│   └── test_client.zig
└── examples/
```

## 13. 实施路线图（wing 侧）

| 里程碑 | 内容 | 验收 | 依赖 |
|--------|------|------|------|
| **M2** | Router(nest/merge/guard) + Endpoint metadata 两阶段路由 + 提取器/toResponse + State 投影 + 内置中间件 + TestClient | 框架 demo 完整；TestClient 跑全部框架测试；零分配经 allocator 计数验证 | talon M1（自研解析器 + chain + MemoryListener） |
| **M3+** | WebSocket 生态包（基于 hijack）、`PerExecutor`、compress | 与 talon M3 同期 | talon hijack 原语 |

## 14. 风险与权衡

1. **comptime 重度使用的编译时间与报错体验**：提取器、中间件链组合会放大编译错误的间接性。缓解：每个 comptime 入口先做显式签名校验并以短名 `@compileError` 给出人话提示；提供 `wing.DefaultRouter` 等常用特化别名；CI 跟踪编译耗时。
2. **对 talon 的版本耦合**：契约面收敛为 5 项（§2）并精确 pin；talon 破坏性变更走 major。牺牲：单仓原子重构便利。换来：talon 独立二开生态。
3. **两阶段路由的链顺序约束**：经典误用点，由 chain `requires` 机制编译期报错兜底（talon 文档 §7）。
4. **`PerExecutor` 语义边界**：zio spawn 无亲和性，同一连接多请求可能落不同执行器，只适合可合并统计类状态——文档与 API 注释双重明示，防误用于会话状态。
