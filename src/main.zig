const std = @import("std");

const gooey = @import("gooey");

pub const std_options = gooey.std_options;

const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.components.Button;
const Select = gooey.components.Select;
const TextInput = gooey.components.TextInput;

const method_names = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };

const Method = enum { get, post, put, patch, delete, head, options };

const colors = struct {
    const background = ui.Color.rgb8(17, 19, 24);
    const card = ui.Color.rgb8(26, 29, 36);
    const text = ui.Color.rgb8(235, 237, 240);
    const muted = ui.Color.rgb8(140, 148, 160);
    const accent = ui.Color.rgb8(88, 199, 172);
};

const AppState = struct {
    url: []const u8 = "",
    method_index: ?usize = 0,
    message_buf: [message_cap]u8 = [_]u8{0} ** message_cap,
    message_len: usize = 0,

    const message_cap = 192;

    fn method(self: *const AppState) Method {
        const index = self.method_index orelse 0;
        return @enumFromInt(index);
    }

    fn trimmedUrl(self: *const AppState) []const u8 {
        return std.mem.trim(u8, self.url, " \t\r\n");
    }

    fn canSend(self: *const AppState) bool {
        return self.trimmedUrl().len > 0;
    }

    fn message(self: *const AppState) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    pub fn setMethod(self: *AppState, index: usize) void {
        self.method_index = index;
    }

    pub fn send(self: *AppState) void {
        if (!self.canSend()) return;
        self.message_len = blk: {
            const text = std.fmt.bufPrint(
                &self.message_buf,
                "{s} {s} — HTTP engine arrives in Milestone 3",
                .{ @tagName(self.method()), self.trimmedUrl() },
            ) catch break :blk "request too long to show".len;
            break :blk text.len;
        };
    }
};

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Gowa",
    .width = 960,
    .height = 640,
});

comptime {
    _ = App;
}

pub fn main(init: std.process.Init) !void {
    return App.main(init);
}

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .direction = .column,
        .padding = .{ .all = 24 },
        .gap = 16,
        .background = colors.background,
    }, .{
        ui.text("Gowa", .{
            .size = 26,
            .color = colors.text,
            .weight = .semibold,
        }),
        RequestBar{},
        StatusLine{},
    }));
}

const RequestBar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .fill_width = true,
            .direction = .column,
            .padding = .{ .all = 16 },
            .gap = 12,
            .background = colors.card,
            .corner_radius = 10,
        }, .{
            ui.hstack(.{ .gap = 10, .alignment = .center }, .{
                Select{
                    .id = "method-select",
                    .options = &method_names,
                    .selected = s.method_index,
                    .width = 130,
                    .on_select = cx.onSelect(AppState.setMethod),
                },
                TextInput{
                    .id = "url-input",
                    .placeholder = "https://example.com/path",
                    .bind = &s.url,
                    .fill_width = true,
                },
                Button{
                    .label = "Send",
                    .variant = .primary,
                    .enabled = s.canSend(),
                    .on_click_handler = cx.update(AppState.send),
                },
            }),
        }));
    }
};

const StatusLine = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        if (s.message().len > 0) {
            cx.render(ui.textFmt("{s}", .{s.message()}, .{
                .size = 13,
                .color = colors.accent,
            }));
        } else {
            cx.render(ui.text("Enter a URL and press Send", .{
                .size = 13,
                .color = colors.muted,
            }));
        }
    }
};
