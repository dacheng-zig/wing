//! TestClient: full-stack in-process testing over talon's
//! MemoryListener — no sockets, no ports, parallel-safe.
//!
//! Every request runs the real chain: parser → middleware → routing →
//! extractors → response encoding. Requires a live zio.Runtime in the test.

const std = @import("std");
const talon = @import("talon");
const zio = @import("zio");
const router_mod = @import("router.zig");
const cookie_mod = @import("cookie.zig");

pub const RequestOptions = struct {
    headers: []const talon.http.Header = &.{},
    body: []const u8 = "",
};

pub const TestResponse = struct {
    gpa: std.mem.Allocator,
    status: talon.http.Status,
    /// Owned copies; freed by deinit.
    headers: []const talon.http.Header,
    body: []const u8,

    pub fn deinit(self: *TestResponse) void {
        for (self.headers) |hdr| {
            self.gpa.free(hdr.name);
            self.gpa.free(hdr.value);
        }
        self.gpa.free(self.headers);
        self.gpa.free(self.body);
        self.* = undefined;
    }

    pub fn header(self: *const TestResponse, name: []const u8) ?[]const u8 {
        for (self.headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, name)) return hdr.value;
        }
        return null;
    }

    /// Value of the issued cookie named `name` (the `name=value` pair parsed off
    /// its `Set-Cookie` header; attributes ignored), or null. Scans every
    /// `Set-Cookie`, so multiple cookies in one response are each observable —
    /// the cookie-aware complement to `header`, which only returns the first.
    pub fn cookie(self: *const TestResponse, name: []const u8) ?[]const u8 {
        for (self.headers) |hdr| {
            if (!std.ascii.eqlIgnoreCase(hdr.name, "set-cookie")) continue;
            var it = cookie_mod.View.init(hdr.value).iterator();
            if (it.next()) |pair| {
                if (std.mem.eql(u8, pair.name, name)) return pair.value;
            }
        }
        return null;
    }

    /// Parses the body as JSON into `T` and deep-compares with `expected`.
    pub fn expectJson(self: *const TestResponse, comptime T: type, expected: T) !void {
        const parsed = try std.json.parseFromSlice(T, self.gpa, self.body, .{});
        defer parsed.deinit();
        try std.testing.expectEqualDeep(expected, parsed.value);
    }
};

/// `A` is the wing App type, e.g. `wing.DefaultApp(State)` or a custom
/// `wing.App(State, .{...chain...})`.
pub fn TestClient(comptime A: type) type {
    const State = A.Ctx.WingState;
    const Srv = talon.http.Server(A);

    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        listener: *talon.MemoryListener,
        app: *A,
        server: *Srv,
        server_group: *zio.Group,

        pub fn init(
            gpa: std.mem.Allocator,
            router: *const router_mod.Router(State),
            state: *State,
        ) !Self {
            const listener = try gpa.create(talon.MemoryListener);
            errdefer gpa.destroy(listener);
            listener.* = try talon.MemoryListener.init(gpa, .{});
            errdefer listener.deinit();

            const app = try gpa.create(A);
            errdefer gpa.destroy(app);
            app.* = A.init(router, state);

            const server = try gpa.create(Srv);
            errdefer gpa.destroy(server);
            server.* = try Srv.init(gpa, app, .{});
            errdefer server.deinit();

            const group = try gpa.create(zio.Group);
            errdefer gpa.destroy(group);
            group.* = .init;

            try group.spawn(serve, .{ server, listener });

            return .{
                .gpa = gpa,
                .listener = listener,
                .app = app,
                .server = server,
                .server_group = group,
            };
        }

        fn serve(server: *Srv, listener: *talon.MemoryListener) !void {
            try server.serve(listener);
        }

        pub fn deinit(self: *Self) void {
            self.server.shutdown();
            self.server_group.wait() catch {};
            self.server.deinit();
            self.listener.deinit();
            self.gpa.destroy(self.server_group);
            self.gpa.destroy(self.server);
            self.gpa.destroy(self.app);
            self.gpa.destroy(self.listener);
            self.* = undefined;
        }

        pub fn get(self: *Self, path: []const u8, options: RequestOptions) !TestResponse {
            return self.request(.GET, path, options);
        }

        pub fn post(self: *Self, path: []const u8, options: RequestOptions) !TestResponse {
            return self.request(.POST, path, options);
        }

        pub fn put(self: *Self, path: []const u8, options: RequestOptions) !TestResponse {
            return self.request(.PUT, path, options);
        }

        pub fn delete(self: *Self, path: []const u8, options: RequestOptions) !TestResponse {
            return self.request(.DELETE, path, options);
        }

        pub fn head(self: *Self, path: []const u8, options: RequestOptions) !TestResponse {
            return self.request(.HEAD, path, options);
        }

        /// One request on a fresh connection, driven on a zio task so the
        /// caller may be plain test code outside the runtime.
        pub fn request(
            self: *Self,
            method: talon.http.Method,
            path: []const u8,
            options: RequestOptions,
        ) !TestResponse {
            var result: Result = .{};
            var group: zio.Group = .init;
            defer group.cancel();
            try group.spawn(clientTask, .{ self, method, path, options, &result });
            try group.wait();
            if (result.err) |err| return err;
            return result.response.?;
        }

        const Result = struct {
            response: ?TestResponse = null,
            err: ?anyerror = null,
        };

        fn clientTask(
            self: *Self,
            method: talon.http.Method,
            path: []const u8,
            options: RequestOptions,
            result: *Result,
        ) void {
            result.response = self.roundTrip(method, path, options) catch |err| {
                result.err = err;
                return;
            };
        }

        fn roundTrip(
            self: *Self,
            method: talon.http.Method,
            path: []const u8,
            options: RequestOptions,
        ) !TestResponse {
            const conn = try self.listener.connect();
            defer conn.close();

            var wbuf: [8 * 1024]u8 = undefined;
            var w = conn.writer(&wbuf);
            const out = &w.interface;

            try out.print("{s} {s} HTTP/1.1\r\n", .{ @tagName(method), path });
            var has_host = false;
            for (options.headers) |hdr| {
                if (std.ascii.eqlIgnoreCase(hdr.name, "host")) has_host = true;
                try out.print("{s}: {s}\r\n", .{ hdr.name, hdr.value });
            }
            if (!has_host) try out.writeAll("host: test\r\n");
            try out.writeAll("connection: close\r\n");
            if (options.body.len > 0) {
                try out.print("content-length: {d}\r\n\r\n", .{options.body.len});
                try out.writeAll(options.body);
            } else {
                try out.writeAll("\r\n");
            }
            try out.flush();

            var rbuf: [64 * 1024]u8 = undefined;
            var r = conn.reader(&rbuf);
            return readResponse(self.gpa, &r.interface, method);
        }

        fn readResponse(
            gpa: std.mem.Allocator,
            in: *std.Io.Reader,
            method: talon.http.Method,
        ) !TestResponse {
            // Status line: "HTTP/1.1 200 OK".
            const status_line = try takeLine(in);
            if (status_line.len < 12 or !std.mem.startsWith(u8, status_line, "HTTP/1.1 "))
                return error.BadResponse;
            const code = try std.fmt.parseInt(u10, status_line[9..12], 10);
            const status: talon.http.Status = @enumFromInt(code);

            var headers: std.ArrayList(talon.http.Header) = .empty;
            errdefer {
                for (headers.items) |hdr| {
                    gpa.free(hdr.name);
                    gpa.free(hdr.value);
                }
                headers.deinit(gpa);
            }
            var content_length: usize = 0;
            while (true) {
                const line = try takeLine(in);
                if (line.len == 0) break;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse
                    return error.BadResponse;
                const name = line[0..colon];
                const value = std.mem.trim(u8, line[colon + 1 ..], " ");
                if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                    content_length = try std.fmt.parseInt(usize, value, 10);
                }
                try headers.append(gpa, .{
                    .name = try gpa.dupe(u8, name),
                    .value = try gpa.dupe(u8, value),
                });
            }

            // HEAD: content-length is entity metadata; no body bytes follow.
            const body_len = if (method == .HEAD) 0 else content_length;
            const body = try gpa.alloc(u8, body_len);
            errdefer gpa.free(body);
            try in.readSliceAll(body);

            return .{
                .gpa = gpa,
                .status = status,
                .headers = try headers.toOwnedSlice(gpa),
                .body = body,
            };
        }

        fn takeLine(in: *std.Io.Reader) ![]const u8 {
            const line = try in.takeDelimiterInclusive('\n');
            return std.mem.trimEnd(u8, line, "\r\n");
        }
    };
}
