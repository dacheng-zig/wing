//! M2 acceptance: steady-state request handling performs
//! zero heap allocation from the server gpa — all per-request temporaries
//! live in talon's retained-capacity arena.
//!
//! Methodology: a counting allocator backs the talon server; one keep-alive
//! connection sends warmup requests (arena growth, buffer pools), then the
//! allocation count must stay flat for every subsequent request.

const std = @import("std");
const talon = @import("talon");
const zio = @import("zio");
const wing = @import("wing");

const CountingAllocator = struct {
    child: std.mem.Allocator,
    count: std.atomic.Value(usize) = .init(0),

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.child.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) _ = self.count.fetchAdd(1, .monotonic);
        return self.child.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) _ = self.count.fetchAdd(1, .monotonic);
        return self.child.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }
};

// Same shape as the integration app: typed extractors, projection, JSON —
// the full comptime magic must be on the measured path.
const Db = struct { reads: u32 = 0 };
const State = struct { db: Db };
const Ctx = wing.Context(State);
const User = struct { id: u64, name: []const u8 };

fn getUser(
    ctx: *Ctx,
    db: *Db,
    path: wing.extract.Path(struct { id: u64 }),
) anyerror!wing.respond.Json(User) {
    _ = ctx;
    db.reads += 1;
    return .{ .value = .{ .id = path.value.id, .name = "ada" } };
}

const App = wing.App(State, .{
    wing.middleware.recover,
    wing.middleware.request_id,
    wing.middleware.route_match,
    wing.middleware.cors,
});

fn readLine(reader: *std.Io.Reader, buf: []u8) ![]const u8 {
    const line = try reader.takeDelimiterInclusive('\n');
    const trimmed = std.mem.trimEnd(u8, line, "\r\n");
    @memcpy(buf[0..trimmed.len], trimmed);
    return buf[0..trimmed.len];
}

fn readOkResponse(r: *std.Io.Reader) !void {
    var line_buf: [256]u8 = undefined;
    const status_line = try readLine(r, &line_buf);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", status_line);
    var content_length: usize = 0;
    while (true) {
        const line = try readLine(r, &line_buf);
        if (line.len == 0) break;
        const prefix = "content-length: ";
        if (std.ascii.startsWithIgnoreCase(line, prefix)) {
            content_length = try std.fmt.parseInt(usize, line[prefix.len..], 10);
        }
    }
    var body_buf: [512]u8 = undefined;
    try std.testing.expect(content_length <= body_buf.len);
    try r.readSliceAll(body_buf[0..content_length]);
    try std.testing.expect(std.mem.indexOf(u8, body_buf[0..content_length], "\"ada\"") != null);
}

test "M2 acceptance: steady-state requests are zero-allocation on the server gpa" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var listener = try talon.MemoryListener.init(std.testing.allocator, .{});
    defer listener.deinit();

    var router = wing.Router(State).init(std.testing.allocator);
    defer router.deinit();
    try router.get("/api/v1/users/:id", getUser);

    var state: State = .{ .db = .{} };
    var app = App.init(&router, &state);

    var counting: CountingAllocator = .{ .child = std.testing.allocator };
    const Srv = talon.http.Server(App);
    var server = try Srv.init(counting.allocator(), &app, .{});
    defer server.deinit();

    const warmup = 3;
    const measured = 16;

    const Fns = struct {
        fn runServer(s: *Srv, l: *talon.MemoryListener) !void {
            try s.serve(l);
        }

        fn client(l: *talon.MemoryListener, s: *Srv, counter: *CountingAllocator) !void {
            const conn = try l.connect();
            defer conn.close();

            var wbuf: [256]u8 = undefined;
            var w = conn.writer(&wbuf);
            var rbuf: [4096]u8 = undefined;
            var r = conn.reader(&rbuf);

            for (0..warmup) |_| {
                try w.interface.writeAll("GET /api/v1/users/42 HTTP/1.1\r\nhost: t\r\n\r\n");
                try w.interface.flush();
                try readOkResponse(&r.interface);
            }

            const baseline = counter.count.load(.monotonic);
            for (0..measured) |_| {
                try w.interface.writeAll("GET /api/v1/users/42 HTTP/1.1\r\nhost: t\r\n\r\n");
                try w.interface.flush();
                try readOkResponse(&r.interface);
            }
            const after = counter.count.load(.monotonic);

            try std.testing.expectEqual(baseline, after);
            s.shutdown();
        }
    };

    var group: zio.Group = .init;
    defer group.cancel();
    try group.spawn(Fns.runServer, .{ &server, &listener });
    try group.spawn(Fns.client, .{ &listener, &server, &counting });
    try group.wait();
    try std.testing.expect(!group.hasFailed());
    try std.testing.expectEqual(warmup + measured, state.db.reads);
}
