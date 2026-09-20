const std = @import("std");
const Io = std.Io;

const gooey = @import("gooey");
const main_mod = @import("main.zig");
const http_engine = @import("http.zig");

const clipboard = gooey.platform.macos.clipboard;

pub const RESULT_QUEUE_CAPACITY = 8;
const url_cap = 2048;
pub const body_cap = 1 << 20;
pub const preview_cap = 16 * 1024;
const detail_cap = 256;
const headers_cap = 16 * 1024;

pub const method_names = [_][]const u8{ "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS" };

fn methodAt(index: ?usize) std.http.Method {
    return switch (index orelse 0) {
        0 => .GET,
        1 => .HEAD,
        2 => .POST,
        3 => .PUT,
        4 => .PATCH,
        5 => .DELETE,
        6 => .OPTIONS,
        else => .GET,
    };
}

pub const WorkerResult = union(enum) {
    ok: struct { status: u16, body_len: u32, headers_len: u32 },
    failed: struct { detail_len: u32 },
    cancelled,
};

pub const AppState = struct {
    url: []const u8 = "",
    method_index: ?usize = 0,
    busy: bool = false,
    status_code: ?u16 = null,
    failed: bool = false,

    pending_url_buf: [url_cap]u8 = undefined,
    pending_url_len: usize = 0,
    pending_body_buf: [body_cap]u8 = undefined,
    pending_body_len: usize = 0,
    pending_detail_buf: [detail_cap]u8 = undefined,
    pending_detail_len: usize = 0,
    pending_headers_buf: [headers_cap]u8 = undefined,
    pending_headers_len: usize = 0,

    pending_request: ?std.Io.Future(void) = null,
    result_buffer: [RESULT_QUEUE_CAPACITY]WorkerResult = undefined,
    result_queue: std.Io.Queue(WorkerResult) = undefined,
    window_ptr: ?*gooey.Window = null,

    pub fn init(cx: *gooey.Cx) void {
        const self = cx.state(AppState);
        self.window_ptr = cx.window();
        self.result_queue = std.Io.Queue(WorkerResult).init(&self.result_buffer);
    }

    pub fn method(self: *const AppState) std.http.Method {
        return methodAt(self.method_index);
    }

    pub fn methodLabel(self: *const AppState) []const u8 {
        return method_names[self.method_index orelse 0];
    }

    pub fn trimmedUrl(self: *const AppState) []const u8 {
        return std.mem.trim(u8, self.url, " \t\r\n");
    }

    pub fn canSend(self: *const AppState) bool {
        return !self.busy and self.trimmedUrl().len > 0;
    }

    fn stageDetail(self: *AppState, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.pending_detail_buf, fmt, args) catch {
            self.pending_detail_len = 0;
            return;
        };
        self.pending_detail_len = text.len;
    }

    fn fail(self: *AppState, text: []const u8) void {
        self.stageDetail("{s}", .{text});
        self.failed = true;
        self.busy = false;
        self.requestRender();
    }

    fn requestRender(self: *AppState) void {
        if (self.window_ptr) |window| window.requestRender();
    }

    pub fn copyBody(self: *AppState, _: *gooey.Window) void {
        if (self.pending_body_len == 0) return;
        _ = clipboard.setText(self.pending_body_buf[0..self.pending_body_len]);
    }

    pub fn isText(body: []const u8) bool {
        return std.unicode.utf8ValidateSlice(body);
    }

    pub fn setMethod(self: *AppState, index: usize) void {
        self.method_index = index;
    }

    pub fn send(self: *AppState) void {
        if (self.busy) return;
        const url = self.trimmedUrl();
        if (url.len == 0) return;

        if (url.len > url_cap) return self.fail("URL too long");
        _ = http_engine.parseUrl(url) catch |e| {
            if (e == error.MissingScheme) {
                self.fail("URL must start with http:// or https://");
            } else {
                self.fail(@errorName(e));
            }
            return;
        };

        @memcpy(self.pending_url_buf[0..url.len], url);
        self.pending_url_len = url.len;
        self.pending_body_len = 0;
        self.pending_detail_len = 0;
        self.pending_headers_len = 0;
        self.status_code = null;
        self.failed = false;
        self.busy = true;

        const io = main_mod.process_io;
        self.pending_request = io.async(fetchWorker, .{ io, self, &self.result_queue });
        self.requestRender();
    }

    pub fn stop(self: *AppState, g: *gooey.Window) void {
        if (self.pending_request == null) return;
        const io = main_mod.process_io;

        var drain_buf: [RESULT_QUEUE_CAPACITY]WorkerResult = undefined;
        _ = self.result_queue.get(io, &drain_buf, 0) catch {};

        self.pending_request.?.cancel(io);
        self.pending_request = null;

        _ = self.result_queue.get(io, &drain_buf, 0) catch {};

        self.busy = false;
        g.requestRender();
    }

    fn awaitPendingRequest(self: *AppState, io: Io) void {
        if (self.pending_request == null) return;
        self.pending_request.?.await(io);
        self.pending_request = null;
    }

    pub fn drainResults(self: *AppState, cx: *gooey.Cx) void {
        var buf: [RESULT_QUEUE_CAPACITY]WorkerResult = undefined;
        const drained = cx.drainQueue(WorkerResult, &self.result_queue, &buf);
        if (drained.len == 0) return;

        const io = cx.io();
        for (drained) |r| switch (r) {
            .ok => |ok| {
                self.awaitPendingRequest(io);
                self.busy = false;
                self.failed = false;
                self.status_code = ok.status;
                self.pending_body_len = ok.body_len;
                self.pending_headers_len = ok.headers_len;
            },
            .failed => |f| {
                self.awaitPendingRequest(io);
                self.busy = false;
                self.failed = true;
                self.status_code = null;
                self.pending_detail_len = f.detail_len;
            },
            .cancelled => {
                self.awaitPendingRequest(io);
                self.busy = false;
            },
        };
    }
};

pub fn formatBytes(buf: []u8, n: u64) []const u8 {
    const f: f64 = @floatFromInt(n);
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch buf[0..0];
    if (n < 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} kB", .{f / 1024.0}) catch buf[0..0];
    if (n < 1024 * 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / (1024.0 * 1024.0)}) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d:.1} GB", .{f / (1024.0 * 1024.0 * 1024.0)}) catch buf[0..0];
}

fn fetchWorker(io: Io, app: *AppState, queue: *std.Io.Queue(WorkerResult)) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    const url = app.pending_url_buf[0..app.pending_url_len];
    const result: WorkerResult = blk: {
        const fetched = http_engine.fetch(
            io,
            arena_state.allocator(),
            app.method(),
            url,
            app.pending_body_buf.len,
            &app.pending_headers_buf,
        ) catch |e| {
            if (e == error.Canceled) break :blk .cancelled;
            app.stageDetail("Request failed: {s}", .{@errorName(e)});
            break :blk .{ .failed = .{ .detail_len = @intCast(app.pending_detail_len) } };
        };
        const n = @min(fetched.body.len, app.pending_body_buf.len);
        @memcpy(app.pending_body_buf[0..n], fetched.body[0..n]);
        app.pending_body_len = n;
        app.pending_headers_len = fetched.headers_len;
        break :blk .{ .ok = .{
            .status = fetched.status,
            .body_len = @intCast(n),
            .headers_len = @intCast(fetched.headers_len),
        } };
    };

    queue.putOne(io, result) catch {};
    app.requestRender();
}

test "methodAt maps UI order onto std.http.Method" {
    try std.testing.expectEqual(std.http.Method.GET, methodAt(0));
    try std.testing.expectEqual(std.http.Method.POST, methodAt(2));
    try std.testing.expectEqual(std.http.Method.OPTIONS, methodAt(6));
    try std.testing.expectEqual(std.http.Method.GET, methodAt(null));
    try std.testing.expectEqual(std.http.Method.GET, methodAt(99));
}

test "formatBytes renders human sizes" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", formatBytes(&buf, 512));
    try std.testing.expectEqualStrings("1.0 kB", formatBytes(&buf, 1024));
    try std.testing.expectEqualStrings("1.5 MB", formatBytes(&buf, 1572864));
    try std.testing.expectEqualStrings("0 B", formatBytes(&buf, 0));
}
