//! wing: web framework on top of the talon engine.
//!
//! Routing, middleware, Context, extractors, testability — DX-first but
//! zero-cost: all framework magic is digested at comptime, no runtime
//! reflection or lookups. Consumes only talon's public contract.

const std = @import("std");

pub const talon = @import("talon");

pub const Endpoint = @import("endpoint.zig").Endpoint;
pub const Metadata = @import("endpoint.zig").Metadata;
pub const RouteOptions = @import("endpoint.zig").RouteOptions;
pub const CorsPolicy = @import("endpoint.zig").CorsPolicy;
pub const hostIs = @import("endpoint.zig").hostIs;
pub const headerIs = @import("endpoint.zig").headerIs;

pub const Context = @import("context.zig").Context;
pub const PathParams = @import("context.zig").PathParams;

pub const Router = @import("router.zig").Router;
pub const MethodSet = @import("router.zig").MethodSet;

pub const App = @import("app.zig").App;
pub const DefaultApp = @import("app.zig").DefaultApp;

pub const middleware = @import("middleware.zig");
pub const static = @import("middleware.zig").static;

pub const TestClient = @import("test_client.zig").TestClient;
pub const TestResponse = @import("test_client.zig").TestResponse;
pub const RequestOptions = @import("test_client.zig").RequestOptions;

pub const Json = @import("extract.zig").Json;
pub const Created = @import("extract.zig").Created;
pub const Redirect = @import("extract.zig").Redirect;
pub const Query = @import("extract.zig").Query;
pub const Path = @import("extract.zig").Path;
pub const ExtractError = @import("extract.zig").ExtractError;

pub const Cookie = @import("cookie.zig").Cookie;
pub const Cookies = @import("cookie.zig").Cookies;
pub const CookieView = @import("cookie.zig").View;
pub const SameSite = @import("cookie.zig").SameSite;
pub const CookieError = @import("cookie.zig").CookieError;

test {
    std.testing.refAllDecls(@This());
    _ = @import("endpoint.zig");
    _ = @import("context.zig");
    _ = @import("router.zig");
    _ = @import("extract.zig");
    _ = @import("scalar.zig");
    _ = @import("cookie.zig");
    _ = @import("state.zig");
    _ = @import("middleware.zig");
    _ = @import("app.zig");
    _ = @import("test_client.zig");
}

test "wing imports talon public contract" {
    // Pin the dependency surface.
    _ = talon.http.Server;
    _ = talon.http.Request;
    _ = talon.http.Response;
    _ = talon.http.codec.BodyReader;
    _ = talon.chain;
    _ = talon.MemoryListener;
}
