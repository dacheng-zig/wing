//! Extractors: typed request-data binding for handler parameters. One file
//! per source under `extract/`; this hub re-exports them and aggregates
//! their error sets. The response side lives in `respond.zig`; the comptime
//! binding machinery in `binding.zig`.

const query = @import("extract/query.zig");
const path = @import("extract/path.zig");
const headers = @import("extract/headers.zig");
const cookies = @import("extract/cookies.zig");
const json = @import("extract/json.zig");
const form = @import("extract/form.zig");
const bytes = @import("extract/bytes.zig");
const multipart = @import("extract/multipart.zig");
const body = @import("extract/body.zig");

// Head extractors (fromRequestParts): any number per handler.
pub const Query = query.Query;
pub const Path = path.Path;
pub const Headers = headers.Headers;
pub const Cookies = cookies.Cookies;

// Body extractors (fromRequest): at most one, and last.
pub const Json = json.Json;
pub const Form = form.Form;
pub const Bytes = bytes.Bytes;
pub const Multipart = multipart.Multipart;

/// The aggregate of every built-in extractor's failure modes, so a caller
/// can `catch` one set to handle any extraction error. Each extractor still
/// returns only its own subset: the `Error` declared in its own file, plus
/// the shared `body.Error` for the body extractors.
pub const Error = query.Error || path.Error || headers.Error || cookies.Error ||
    json.Error || form.Error || bytes.Error || multipart.Error || body.Error;

test {
    _ = query;
    _ = path;
    _ = headers;
    _ = cookies;
    _ = json;
    _ = form;
    _ = bytes;
    _ = multipart;
    _ = body;
    _ = @import("extract/urlencoded.zig");
}
