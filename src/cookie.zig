//! Cookie component: strongly-typed Set-Cookie assembly and zero-copy request
//! Cookie reading, grounded in RFC 6265 / 6265bis.
//!
//! Two layers, smallest surface that covers the use cases:
//!   - `Cookie` — a Set-Cookie directive (name=value + attributes) with a
//!                secure-by-default baseline. `serialize` writes the header
//!                value into a caller-supplied writer; `validate` enforces
//!                the spec invariants (token name, cookie-octet value,
//!                `__Host-`/`__Secure-` prefixes, `SameSite=None`⇒Secure).
//!   - `View`   — a lazy, allocation-free reader over a request `Cookie`
//!                header. Slices borrow the header; lifetime is the request.
//!
//! The typed `Cookies(T)` extractor builds on `View` and lives with the
//! other extractors in `extract/cookies.zig`.
//!
//! Write side is strict (malformed cookies are rejected with an error, never
//! silently dropped); read side is lenient (malformed segments are skipped).
//! Signing/encryption is intentionally out of scope — it belongs to the session
//! component layered on top of this primitive.

const std = @import("std");

pub const SameSite = enum { strict, lax, none };

pub const CookieError = error{
    /// Name is empty or contains a non-token byte (CTL, separator, space).
    InvalidCookieName,
    /// Value contains a byte outside the cookie-octet set (space, `"`, `,`,
    /// `;`, `\`, CTL). Encode it first if you need arbitrary bytes.
    InvalidCookieValue,
    /// Path or Domain contains a control character or `;`.
    InvalidCookieAttribute,
    /// `__Host-`/`__Secure-` prefix constraints are not met.
    CookiePrefixViolation,
    /// `SameSite=None` (or `Partitioned`) was set without `Secure`.
    InsecureCookie,
};

/// A Set-Cookie directive. Construct with a struct literal; defaults are the
/// modern baseline (session cookie, no attributes). RFC 6265bis note: when both
/// are present `max_age` takes precedence over `expires` in the UA.
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    /// Lifetime in seconds. null = session cookie; <= 0 deletes the cookie now.
    max_age: ?i64 = null,
    /// Absolute expiry as a Unix timestamp; serialized as an IMF-fixdate.
    expires: ?i64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,
    partitioned: bool = false,

    /// A deletion directive for `name`: empty value, already expired. Set
    /// `path`/`domain` to match the cookie you are clearing, or the UA keeps it.
    pub fn removal(name: []const u8) Cookie {
        return .{ .name = name, .value = "", .max_age = 0 };
    }

    /// Checks the spec invariants without writing anything. `serialize` calls
    /// this first, so handlers normally don't need it directly.
    pub fn validate(self: Cookie) CookieError!void {
        if (self.name.len == 0 or !isToken(self.name)) return error.InvalidCookieName;
        if (!isCookieValue(self.value)) return error.InvalidCookieValue;
        if (self.path) |p| if (!isAttrValue(p)) return error.InvalidCookieAttribute;
        if (self.domain) |d| if (!isAttrValue(d)) return error.InvalidCookieAttribute;

        // SameSite=None and Partitioned (CHIPS) are meaningless without Secure;
        // browsers reject them, so reject here too rather than emit a dead cookie.
        if (self.same_site == .none and !self.secure) return error.InsecureCookie;
        if (self.partitioned and !self.secure) return error.InsecureCookie;

        // Cookie name prefixes (6265bis §4.1.3): byte-exact, no shortcuts — the
        // host-only check (Domain==null) is what defends against cookie tossing.
        if (std.mem.startsWith(u8, self.name, "__Secure-")) {
            if (!self.secure) return error.CookiePrefixViolation;
        }
        if (std.mem.startsWith(u8, self.name, "__Host-")) {
            if (!self.secure or self.domain != null) return error.CookiePrefixViolation;
            const p = self.path orelse return error.CookiePrefixViolation;
            if (!std.mem.eql(u8, p, "/")) return error.CookiePrefixViolation;
        }
    }

    /// Writes the Set-Cookie header *value* (everything after `set-cookie: `)
    /// into `w`. Validates first, so on a `CookieError` nothing is written.
    pub fn serialize(self: Cookie, w: *std.Io.Writer) (CookieError || std.Io.Writer.Error)!void {
        try self.validate();
        try w.writeAll(self.name);
        try w.writeByte('=');
        try w.writeAll(self.value);
        if (self.path) |p| try w.print("; Path={s}", .{p});
        if (self.domain) |d| try w.print("; Domain={s}", .{d});
        if (self.max_age) |ma| try w.print("; Max-Age={d}", .{ma});
        if (self.expires) |ts| {
            var buf: [29]u8 = undefined;
            formatImfDate(ts, &buf);
            try w.print("; Expires={s}", .{&buf});
        }
        if (self.secure) try w.writeAll("; Secure");
        if (self.http_only) try w.writeAll("; HttpOnly");
        if (self.same_site) |ss| try w.writeAll(switch (ss) {
            .strict => "; SameSite=Strict",
            .lax => "; SameSite=Lax",
            .none => "; SameSite=None",
        });
        if (self.partitioned) try w.writeAll("; Partitioned");
    }
};

/// A lazy, allocation-free view over a request `Cookie` header value. `get`
/// scans on demand; most requests read one or two cookies, so building a map
/// would be wasted work. Returned slices borrow the header.
pub const View = struct {
    raw: []const u8,

    pub const Pair = struct { name: []const u8, value: []const u8 };

    pub fn init(header_value: []const u8) View {
        return .{ .raw = header_value };
    }

    /// First cookie named `name`, or null. Per RFC 6265bis cookie order is not
    /// significant and duplicate names may occur; this returns the first.
    pub fn get(self: View, name: []const u8) ?[]const u8 {
        var it = self.iterator();
        while (it.next()) |pair| {
            if (std.mem.eql(u8, pair.name, name)) return pair.value;
        }
        return null;
    }

    pub fn iterator(self: View) Iterator {
        return .{ .rest = self.raw };
    }

    pub const Iterator = struct {
        rest: []const u8,

        pub fn next(self: *Iterator) ?Pair {
            while (self.rest.len > 0) {
                const end = std.mem.indexOfScalar(u8, self.rest, ';') orelse self.rest.len;
                const seg = std.mem.trim(u8, self.rest[0..end], " \t");
                self.rest = self.rest[@min(end + 1, self.rest.len)..];
                if (seg.len == 0) continue;
                if (std.mem.indexOfScalar(u8, seg, '=')) |eq| {
                    // Trim each side independently (6265bis §5.2). A valid
                    // cookie-value never contains a space, so trimming is lossless.
                    return .{
                        .name = std.mem.trim(u8, seg[0..eq], " \t"),
                        .value = std.mem.trim(u8, seg[eq + 1 ..], " \t"),
                    };
                }
                // Bare token with no '=': a present cookie with an empty value.
                return .{ .name = seg, .value = "" };
            }
            return null;
        }
    };
};

// ── Byte-class validation (RFC 9110 token, RFC 6265 cookie-octet) ─────────

fn isToken(s: []const u8) bool {
    for (s) |c| if (!isTokenChar(c)) return false;
    return true;
}

fn isTokenChar(c: u8) bool {
    return switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

/// cookie-value = *cookie-octet / ( DQUOTE *cookie-octet DQUOTE ). The optional
/// surrounding quotes are part of the value (6265bis does not strip them); the
/// inner bytes must still be cookie-octets.
fn isCookieValue(s: []const u8) bool {
    const inner = if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"')
        s[1 .. s.len - 1]
    else
        s;
    for (inner) |c| if (!isCookieOctet(c)) return false;
    return true;
}

fn isCookieOctet(c: u8) bool {
    // %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E — US-ASCII minus CTLs,
    // space, DQUOTE, comma, semicolon, backslash.
    return switch (c) {
        0x21, 0x23...0x2B, 0x2D...0x3A, 0x3C...0x5B, 0x5D...0x7E => true,
        else => false,
    };
}

/// Path / Domain attribute value: any byte except CTLs and `;` (the attribute
/// separator). Keeps CRLF and header-splitting bytes out (defense in depth even
/// though the encoder rejects them again).
fn isAttrValue(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c == 0x7F or c == ';') return false;
    return true;
}

// ── IMF-fixdate formatting (RFC 9110) ────────────────────────────────────

/// Formats a Unix timestamp as `Wdy, DD Mon YYYY HH:MM:SS GMT` (29 bytes).
/// Out-of-range timestamps clamp instead of crashing the calendar math: a
/// negative `ts` (before the epoch) is an already-expired cookie → epoch; a
/// far-future `ts` clamps to 9999-12-31 so the year stays 4 digits and the
/// 29-byte buffer never overflows. Both keep `serialize` panic-free for any i64.
fn formatImfDate(ts: i64, buf: *[29]u8) void {
    const max_secs: i64 = 253402300799; // 9999-12-31T23:59:59Z
    const secs: u64 = if (ts < 0) 0 else @intCast(@min(ts, max_secs));
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch_secs.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();
    const weekday = (day.day + 4) % 7; // 1970-01-01 was a Thursday.

    const wnames = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mnames = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        wnames[weekday],
        month_day.day_index + 1,
        mnames[@intFromEnum(month_day.month) - 1],
        year_day.year,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable; // 29 bytes by construction for years 1000-9999.
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn serializeAlloc(c: Cookie, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try c.serialize(&w);
    return w.buffered();
}

test "serialize: minimal name=value" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("sid=abc123", try serializeAlloc(.{ .name = "sid", .value = "abc123" }, &buf));
}

test "serialize: full attribute set in canonical order" {
    var buf: [256]u8 = undefined;
    const out = try serializeAlloc(.{
        .name = "sid",
        .value = "abc",
        .path = "/",
        .domain = "example.com",
        .max_age = 3600,
        .secure = true,
        .http_only = true,
        .same_site = .lax,
    }, &buf);
    try testing.expectEqualStrings(
        "sid=abc; Path=/; Domain=example.com; Max-Age=3600; Secure; HttpOnly; SameSite=Lax",
        out,
    );
}

test "serialize: removal helper expires the cookie" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("sid=; Max-Age=0", try serializeAlloc(Cookie.removal("sid"), &buf));
}

test "serialize: Expires renders an IMF-fixdate" {
    var buf: [128]u8 = undefined;
    // 2026-06-11 08:30:00 UTC.
    const out = try serializeAlloc(.{ .name = "k", .value = "v", .expires = 1781166600 }, &buf);
    try testing.expectEqualStrings("k=v; Expires=Thu, 11 Jun 2026 08:30:00 GMT", out);
}

test "formatImfDate: epoch, known timestamp, and out-of-range clamping" {
    var buf: [29]u8 = undefined;
    formatImfDate(0, &buf);
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", &buf);
    formatImfDate(1781166600, &buf);
    try testing.expectEqualStrings("Thu, 11 Jun 2026 08:30:00 GMT", &buf);
    // Negatives clamp to the epoch; far-future sentinels clamp to year 9999 —
    // neither panics or overflows the 29-byte buffer.
    formatImfDate(-1, &buf);
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", &buf);
    formatImfDate(std.math.maxInt(i64), &buf);
    try testing.expectEqualStrings("Fri, 31 Dec 9999 23:59:59 GMT", &buf);
}

test "validate: rejects bad names and values" {
    var buf: [64]u8 = undefined;
    try testing.expectError(error.InvalidCookieName, serializeAlloc(.{ .name = "a b", .value = "v" }, &buf));
    try testing.expectError(error.InvalidCookieName, serializeAlloc(.{ .name = "", .value = "v" }, &buf));
    try testing.expectError(error.InvalidCookieValue, serializeAlloc(.{ .name = "k", .value = "a;b" }, &buf));
    try testing.expectError(error.InvalidCookieValue, serializeAlloc(.{ .name = "k", .value = "a b" }, &buf));
    try testing.expectError(error.InvalidCookieAttribute, serializeAlloc(.{ .name = "k", .value = "v", .path = "/a;b" }, &buf));
}

test "validate: SameSite=None and Partitioned require Secure" {
    var buf: [64]u8 = undefined;
    try testing.expectError(error.InsecureCookie, serializeAlloc(.{ .name = "k", .value = "v", .same_site = .none }, &buf));
    try testing.expectError(error.InsecureCookie, serializeAlloc(.{ .name = "k", .value = "v", .partitioned = true }, &buf));
    _ = try serializeAlloc(.{ .name = "k", .value = "v", .same_site = .none, .secure = true }, &buf);
}

test "validate: __Host- and __Secure- prefix constraints" {
    var buf: [128]u8 = undefined;
    // __Host- needs Secure + Path=/ + no Domain.
    try testing.expectError(error.CookiePrefixViolation, serializeAlloc(.{ .name = "__Host-sid", .value = "v" }, &buf));
    try testing.expectError(error.CookiePrefixViolation, serializeAlloc(.{ .name = "__Host-sid", .value = "v", .secure = true, .path = "/", .domain = "example.com" }, &buf));
    _ = try serializeAlloc(.{ .name = "__Host-sid", .value = "v", .secure = true, .path = "/" }, &buf);
    // __Secure- needs Secure.
    try testing.expectError(error.CookiePrefixViolation, serializeAlloc(.{ .name = "__Secure-sid", .value = "v" }, &buf));
    _ = try serializeAlloc(.{ .name = "__Secure-sid", .value = "v", .secure = true }, &buf);
}

test "View: parses, trims, and reads cookies zero-copy" {
    const v = View.init("theme=dark; sid=abc123; empty=");
    try testing.expectEqualStrings("dark", v.get("theme").?);
    try testing.expectEqualStrings("abc123", v.get("sid").?);
    try testing.expectEqualStrings("", v.get("empty").?);
    try testing.expectEqual(@as(?[]const u8, null), v.get("missing"));

    // Borrowed, not copied.
    const raw = "k=v";
    try testing.expectEqual(raw.ptr + 2, View.init(raw).get("k").?.ptr);
}

test "View: lenient on malformed segments and bare tokens" {
    const v = View.init("; ;  flag ; a=1");
    try testing.expectEqualStrings("", v.get("flag").?); // bare token → empty value
    try testing.expectEqualStrings("1", v.get("a").?);
}

test "View: trims whitespace around the '=' separator" {
    const v = View.init("theme = dark ; sid=abc");
    try testing.expectEqualStrings("dark", v.get("theme").?);
    try testing.expectEqualStrings("abc", v.get("sid").?);
}

test "View: first wins on duplicate names" {
    const v = View.init("a=1; a=2");
    try testing.expectEqualStrings("1", v.get("a").?);
}
