const std = @import("std");
const Io = std.Io;

pub const Result = struct {
    status: u16,
    body: []u8,
    headers_len: usize,
};

pub const FetchOptions = struct {
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8 = null,
    follow_redirects: bool = true,
    body_max: usize,
    headers_out: []u8,
};

pub fn parseUrl(url: []const u8) !std.Uri {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return error.MissingScheme;
    }
    return std.Uri.parse(url);
}

pub fn fetch(io: Io, arena: std.mem.Allocator, options: FetchOptions) !Result {
    const uri = try parseUrl(options.url);

    var client = std.http.Client{ .allocator = arena, .io = io };
    defer client.deinit();

    var request = try client.request(options.method, uri, .{
        .redirect_behavior = if (options.follow_redirects) @enumFromInt(10) else .unhandled,
    });
    defer request.deinit();

    if (options.payload) |data| {
        request.transfer_encoding = .{ .content_length = data.len };
        var body = try request.sendBodyUnflushed(&.{});
        try body.writer.writeAll(data);
        try body.end();
        try request.connection.?.flush();
    } else if (options.method.requestHasBody()) {
        var no_body: [0]u8 = .{};
        try request.sendBodyComplete(&no_body);
    } else {
        try request.sendBodiless();
    }

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buf);

    var headers_writer = std.Io.Writer.fixed(options.headers_out);
    var it = response.head.iterateHeaders();
    while (it.next()) |header| {
        headers_writer.print("{s}: {s}\n", .{ header.name, header.value }) catch break;
    }

    var transfer_buf: [4096]u8 = undefined;
    var reader = response.reader(&transfer_buf);
    const body = try reader.allocRemaining(arena, Io.Limit.limited(options.body_max));

    return .{
        .status = @intFromEnum(response.head.status),
        .body = body,
        .headers_len = headers_writer.end,
    };
}

test "parseUrl requires an absolute http(s) URL" {
    _ = try parseUrl("https://example.com/path");
    _ = try parseUrl("http://example.com:8080/x?q=1");
    try std.testing.expectError(error.MissingScheme, parseUrl("example.com"));
    try std.testing.expectError(error.MissingScheme, parseUrl("ftp://example.com"));
    try std.testing.expectError(error.MissingScheme, parseUrl(""));
}
