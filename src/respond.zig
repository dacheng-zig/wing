//! Responders: types a handler returns to produce a response, converted via
//! `toResponse(ctx)` duck typing (see binding.zig). The request-side
//! counterpart of `Json` is `wing.extract.Json` — same name, opposite
//! direction. `[]const u8` (text/plain) and `void` need no wrapper.

const std = @import("std");
const talon = @import("talon");

/// Serializes `value` as JSON with 200 OK.
pub fn Json(comptime T: type) type {
    return struct {
        value: T,

        pub fn toResponse(self: @This(), ctx: anytype) !void {
            try ctx.respond(try jsonStringifyArena(ctx.arena, self.value), .{
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
        }
    };
}

/// 201 Created with a JSON body and optional Location header.
pub fn Created(comptime T: type) type {
    return struct {
        value: T,
        location: []const u8 = "",

        pub fn toResponse(self: @This(), ctx: anytype) !void {
            const body = try jsonStringifyArena(ctx.arena, self.value);
            if (self.location.len > 0) {
                try ctx.respond(body, .{
                    .status = .created,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                        .{ .name = "location", .value = self.location },
                    },
                });
            } else {
                try ctx.respond(body, .{
                    .status = .created,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                    },
                });
            }
        }
    };
}

pub const Redirect = struct {
    location: []const u8,
    status: talon.http.Status = .found,

    pub fn toResponse(self: Redirect, ctx: anytype) !void {
        try ctx.respond("", .{
            .status = self.status,
            .extra_headers = &.{.{ .name = "location", .value = self.location }},
        });
    }
};

/// Serializes `value` as JSON into the request arena.
fn jsonStringifyArena(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    stringify.write(value) catch return error.OutOfMemory;
    return out.written();
}
