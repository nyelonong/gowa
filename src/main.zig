const std = @import("std");

const gooey = @import("gooey");
const state_mod = @import("state.zig");

pub const std_options = gooey.std_options;

pub var process_io: std.Io = undefined;

pub const AppState = state_mod.AppState;

const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.components.Button;
const Select = gooey.components.Select;
const TextInput = gooey.components.TextInput;

const colors = struct {
    const background = ui.Color.rgb8(17, 19, 24);
    const card = ui.Color.rgb8(26, 29, 36);
    const text = ui.Color.rgb8(235, 237, 240);
    const muted = ui.Color.rgb8(140, 148, 160);
    const accent = ui.Color.rgb8(88, 199, 172);
    const danger = ui.Color.rgb8(240, 97, 108);
};

const preview_cap = 2048;

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Gowa",
    .width = 960,
    .height = 640,
    .init = AppState.init,
});

comptime {
    _ = App;
}

pub fn main(init: std.process.Init) !void {
    process_io = init.io;
    return App.main(init);
}

fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    s.drainResults(cx);

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
        ResponseView{},
    }));
}

const RequestBar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        const action = if (s.busy)
            Button{
                .label = "Stop",
                .variant = .danger,
                .on_click_handler = cx.command(AppState.stop),
            }
        else
            Button{
                .label = "Send",
                .variant = .primary,
                .enabled = s.canSend(),
                .on_click_handler = cx.update(AppState.send),
            };

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
                    .options = &state_mod.method_names,
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
                action,
            }),
        }));
    }
};

const StatusLine = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        if (s.busy) {
            cx.render(ui.textFmt("{s} {s} …", .{ s.methodLabel(), s.trimmedUrl() }, .{
                .size = 13,
                .color = colors.muted,
            }));
        } else if (s.failed) {
            cx.render(ui.textFmt("{s}", .{s.pending_detail_buf[0..s.pending_detail_len]}, .{
                .size = 13,
                .color = colors.danger,
            }));
        } else if (s.status_code) |code| {
            cx.render(ui.textFmt("HTTP {d} · {d} bytes", .{ code, s.pending_body_len }, .{
                .size = 13,
                .color = if (code < 400) colors.accent else colors.danger,
            }));
        } else {
            cx.render(ui.text("Enter a URL and press Send", .{
                .size = 13,
                .color = colors.muted,
            }));
        }
    }
};

const ResponseView = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        if (s.busy or s.pending_body_len == 0) return;

        const preview_len = @min(s.pending_body_len, preview_cap);

        cx.render(ui.box(.{
            .fill_width = true,
            .direction = .column,
            .padding = .{ .all = 12 },
            .background = colors.card,
            .corner_radius = 10,
        }, .{
            ui.scroll("response-scroll", .{ .height = 380 }, .{
                ui.text(s.pending_body_buf[0..preview_len], .{
                    .size = 13,
                    .color = colors.text,
                    .wrap = .newlines,
                }),
            }),
        }));
    }
};
