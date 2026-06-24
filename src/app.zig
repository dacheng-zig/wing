//! App adapter: makes a wing Router consumable by talon's `Server(App)`
//! contract.
//!
//! `handle` builds the per-request Context and runs the request-level
//! middleware chain (talon `chain` reused); the terminal
//! invokes the matched endpoint's thunk (`execute`).

const talon = @import("talon");
const context_mod = @import("context.zig");
const router_mod = @import("router.zig");
const middleware = @import("middleware.zig");

/// `middlewares` is the request-level chain tuple, e.g.
/// `.{ wing.middleware.logger, wing.middleware.recover, wing.middleware.route_match, wing.middleware.cors }`.
/// The `execute` terminal is appended automatically.
pub fn App(comptime State: type, comptime middlewares: anytype) type {
    return struct {
        const Self = @This();
        pub const Ctx = context_mod.Context(State);

        router: *const router_mod.Router(State),
        state: *State,

        const Chain = talon.chain(Ctx, middlewares);

        pub fn init(router: *const router_mod.Router(State), state: *State) Self {
            return .{ .router = router, .state = state };
        }

        pub fn handle(self: *Self, req: *talon.http.Request, res: *talon.http.Response) !void {
            var ctx: Ctx = .{
                .req = req,
                .res = res,
                .arena = req.arena,
                .state = self.state,
                .router = self.router,
            };
            try Chain.run(&ctx, middleware.executeTerminal(State));
        }
    };
}

/// Router + standard chain, the common case (a ready-made
/// specialization so users don't assemble the comptime stack by hand).
pub fn DefaultApp(comptime State: type) type {
    return App(State, .{
        middleware.logger,
        middleware.recover,
        middleware.route_match,
        middleware.cors,
    });
}
