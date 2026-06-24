//! Sub-state projection (axum FromRef equivalent).
//!
//! A handler parameter `db: *Db` projects the unique `Db`-typed field out of
//! the App State at comptime — plain field traversal, no runtime container.
//!
//! Deviation from the design sketch: "fall back to field-name matching when
//! the type is ambiguous" is not implementable — Zig reflection exposes
//! parameter types, not names. Ambiguity is a hard @compileError instead;
//! wrap duplicate-typed fields in distinct structs or read `ctx.state`.

const std = @import("std");

pub fn fieldCountOfType(comptime State: type, comptime T: type) usize {
    comptime var n: usize = 0;
    inline for (@typeInfo(State).@"struct".fields) |f| {
        if (f.type == T) n += 1;
    }
    return n;
}

/// Projects the unique `T`-typed field of `state`. Callers must have
/// validated uniqueness (bind does, with a friendly error).
pub fn project(comptime State: type, comptime T: type, state: *State) *T {
    inline for (@typeInfo(State).@"struct".fields) |f| {
        if (f.type == T) return &@field(state, f.name);
    }
    comptime unreachable;
}

test "project finds the unique field by type" {
    const Db = struct { conn: u32 };
    const Cfg = struct { port: u16 };
    const State = struct { db: Db, cfg: Cfg };

    var s: State = .{ .db = .{ .conn = 7 }, .cfg = .{ .port = 80 } };
    const db = project(State, Db, &s);
    try std.testing.expectEqual(7, db.conn);
    db.conn = 9;
    try std.testing.expectEqual(9, s.db.conn);
}

test "fieldCountOfType counts duplicates" {
    const State = struct { a: u32, b: u32, c: u8 };
    try std.testing.expectEqual(2, comptime fieldCountOfType(State, u32));
    try std.testing.expectEqual(1, comptime fieldCountOfType(State, u8));
    try std.testing.expectEqual(0, comptime fieldCountOfType(State, u16));
}
