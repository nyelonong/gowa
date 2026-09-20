const std = @import("std");
const Io = std.Io;

pub const Result = struct {
    status: u16,
    body: []u8,
    headers_len: usize,
};

pub fn parseUrl(url: []const u8) !std.Uri {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return error.MissingScheme;
    }
    return std.Uri.parse(url);
}

pub fn fetch(io: Io, arena: std.mem.Allocator, method: std.http.Method, url: []const u8, body_max: usize, headers_out: []u8) !Result {
    const uri = try parseUrl(url);

    var client = std.http.Client{ .allocator = arena, .io = io };
    defer client.deinit();

    var request = try client.request(method, uri, .{});
    defer request.deinit();

    var no_body: [0]u8 = .{};
    if (method.requestHasBody()) {
        try request.sendBodyComplete(&no_body);
    } else {
        try request.sendBodiless();
    }

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buf);

    var headers_writer = std.Io.Writer.fixed(headers_out);
    var it = response.head.iterateHeaders();
    while (it.next()) |header| {
        headers_writer.print("{s}: {s}\n", .{ header.name, header.value }) catch break;
    }

    var transfer_buf: [4096]u8 = undefined;
    var reader = response.reader(&transfer_buf);
    const body = try reader.allocRemaining(arena, Io.Limit.limited(body_max));

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
