//! Handler binding: the comptime glue between typed handler signatures and
//! the uniform thunk stored in the route tree.
//!
//! `bind` digests a handler's signature at comptime. Extractor contracts
//! (comptime duck typing):
//!   - `fromRequestParts(ctx) !Self` — reads only the head; any number.
//!   - `fromRequest(ctx) !Self`      — consumes the body; at most one and
//!                                     it must be the last parameter.
//! Violations are @compileErrors at the registration site, naming the
//! parameter position and the reason — the DX bar this design sets.
//!
//! Response side: a handler's return value answers via `toResponse(ctx)`
//! duck typing; `[]const u8` and `void` are accepted directly. Errors
//! propagate to the recover middleware for status mapping.

const std = @import("std");
const context_mod = @import("context.zig");
const endpoint_mod = @import("endpoint.zig");
const state_mod = @import("state.zig");

pub fn bind(comptime State: type, comptime handler: anytype) endpoint_mod.Handler {
    const Ctx = context_mod.Context(State);
    const H = @TypeOf(handler);
    const info = @typeInfo(H);
    if (info != .@"fn") {
        @compileError("wing: route handler must be a function, got " ++ @typeName(H));
    }
    const fn_info = info.@"fn";
    const params = fn_info.params;
    if (params.len == 0 or params[0].type != *Ctx) {
        @compileError("wing: handler's first parameter must be *wing.Context(State) (= *" ++
            @typeName(Ctx) ++ ")");
    }

    // Classify every extractor parameter up front so signature mistakes
    // surface as one readable error at the registration site.
    comptime var body_consumer_at: ?usize = null;
    comptime {
        for (params[1..], 1..) |p, i| {
            const P = p.type orelse @compileError(std.fmt.comptimePrint(
                "wing: handler parameter #{d} cannot be anytype/generic — " ++
                    "extractor binding needs a concrete type",
                .{i + 1},
            ));
            switch (classify(State, P, i)) {
                .body => {
                    if (body_consumer_at) |prev| @compileError(std.fmt.comptimePrint(
                        "wing: handler parameter #{d} ({s}) consumes the body, " ++
                            "but parameter #{d} already does — only one body extractor per handler",
                        .{ i + 1, @typeName(P), prev + 1 },
                    ));
                    body_consumer_at = i;
                },
                .parts, .state_ptr => {},
            }
        }
        if (body_consumer_at) |at| {
            if (at != params.len - 1) {
                const P = params[at].type.?;
                @compileError(std.fmt.comptimePrint(
                    "wing: handler parameter #{d} ({s}) consumes the body and must be " ++
                        "the last parameter, but parameter #{d} comes after it",
                    .{ at + 1, @typeName(P), at + 2 },
                ));
            }
        }
        validateReturn(fn_info.return_type.?);
    }

    return struct {
        fn thunk(ptr: *anyopaque) anyerror!void {
            const ctx: *Ctx = @ptrCast(@alignCast(ptr));
            var args: std.meta.ArgsTuple(H) = undefined;
            args[0] = ctx;
            inline for (params[1..], 1..) |p, i| {
                args[i] = try extractArg(State, p.type.?, i, ctx);
            }
            const Ret = fn_info.return_type.?;
            if (@typeInfo(Ret) == .error_union) {
                try writeResponse(ctx, try @call(.auto, handler, args));
            } else {
                try writeResponse(ctx, @call(.auto, handler, args));
            }
        }
    }.thunk;
}

const ParamKind = enum { parts, body, state_ptr };

fn classify(comptime State: type, comptime P: type, comptime index: usize) ParamKind {
    if (@typeInfo(P) == .pointer and @typeInfo(P).pointer.size == .one) {
        const T = @typeInfo(P).pointer.child;
        const n = state_mod.fieldCountOfType(State, T);
        if (n == 1) return .state_ptr;
        if (n > 1) @compileError(std.fmt.comptimePrint(
            "wing: handler parameter #{d} (*{s}): State has {d} fields of type {s} — " ++
                "projection is ambiguous (Zig cannot reflect parameter names). " ++
                "Wrap one field in a distinct struct, or read it via ctx.state",
            .{ index + 1, @typeName(T), n, @typeName(T) },
        ));
        @compileError(std.fmt.comptimePrint(
            "wing: handler parameter #{d} (*{s}): State {s} has no field of type {s}",
            .{ index + 1, @typeName(T), @typeName(State), @typeName(T) },
        ));
    }
    if (@typeInfo(P) == .@"struct") {
        if (@hasDecl(P, "fromRequest")) return .body;
        if (@hasDecl(P, "fromRequestParts")) return .parts;
    }
    @compileError(std.fmt.comptimePrint(
        "wing: handler parameter #{d} ({s}) is not an extractor — expected a type with " ++
            "fromRequestParts/fromRequest (wing.extract.Query, wing.extract.Json, " ++
            "wing.extract.Path, ...) or a pointer to a unique State field",
        .{ index + 1, @typeName(P) },
    ));
}

fn extractArg(
    comptime State: type,
    comptime P: type,
    comptime index: usize,
    ctx: anytype,
) !P {
    return switch (comptime classify(State, P, index)) {
        .state_ptr => state_mod.project(State, @typeInfo(P).pointer.child, ctx.state),
        .body => P.fromRequest(ctx),
        .parts => P.fromRequestParts(ctx),
    };
}

fn validateReturn(comptime Ret: type) void {
    const Payload = if (@typeInfo(Ret) == .error_union)
        @typeInfo(Ret).error_union.payload
    else
        Ret;
    if (Payload == void) return;
    if (Payload == []const u8 or Payload == []u8) return;
    if (@typeInfo(Payload) == .@"struct" and @hasDecl(Payload, "toResponse")) return;
    @compileError("wing: handler return type " ++ @typeName(Payload) ++
        " is not convertible to a response — return void, []const u8, or a type " ++
        "with 'pub fn toResponse(self, ctx) !void' (wing.respond.Json, " ++
        "wing.respond.Created, wing.respond.Redirect, ...)");
}

fn writeResponse(ctx: anytype, payload: anytype) !void {
    const P = @TypeOf(payload);
    if (P == void) {
        // Plain `!void` handlers usually respond through ctx.res themselves;
        // cover the forgot-to-respond case so the connection stays correct.
        if (!ctx.res.written) try ctx.respond("", .{});
        return;
    }
    if (P == []const u8 or P == []u8) {
        try ctx.respond(payload, .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        });
        return;
    }
    try payload.toResponse(ctx);
}
