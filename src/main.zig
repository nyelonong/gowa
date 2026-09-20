const std = @import("std");

const gooey = @import("gooey");
const state_mod = @import("state.zig");

pub const std_options = gooey.std_options;

pub var process_io: std.Io = undefined;

pub const AppState = state_mod.AppState;

const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.components.Button;
const Checkbox = gooey.components.Checkbox;
const Select = gooey.components.Select;
const TextArea = gooey.components.TextArea;
const TextInput = gooey.components.TextInput;

const colors = struct {
    const background = ui.Color.rgb8(17, 19, 24);
    const card = ui.Color.rgb8(26, 29, 36);
    const text = ui.Color.rgb8(235, 237, 240);
    const muted = ui.Color.rgb8(140, 148, 160);
    const accent = ui.Color.rgb8(88, 199, 172);
    const info = ui.Color.rgb8(96, 165, 250);
    const danger = ui.Color.rgb8(240, 97, 108);
};

fn statusColor(code: u16) ui.Color {
    return if (code < 300) colors.accent else if (code < 400) colors.info else colors.danger;
}

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
            RedirectRow{},
            RequestBodyBlock{},
        }));
    }
};

const RedirectRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(Checkbox{
            .checked = s.follow_redirects,
            .label = "Follow redirects",
            .on_click_handler = cx.update(AppState.toggleFollowRedirects),
        });
    }
};

const RequestBodyBlock = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        if (!s.method().requestHasBody()) return;

        cx.render(TextArea{
            .id = "request-body",
            .placeholder = "Request body",
            .bind = &s.request_body,
            .fill_width = true,
            .height = 96,
        });
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
            var size_buf: [16]u8 = undefined;
            const st: std.http.Status = @enumFromInt(code);
            cx.render(ui.textFmt("HTTP {d} {s} · {s} · {d} ms", .{
                code,
                st.phrase() orelse "",
                state_mod.formatBytes(&size_buf, s.pending_body_len),
                s.elapsed_ms,
            }, .{
                .size = 13,
                .color = statusColor(code),
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
        if (s.busy or s.status_code == null) return;

        cx.render(ui.box(.{
            .fill_width = true,
            .direction = .column,
            .padding = .{ .all = 12 },
            .gap = 10,
            .background = colors.card,
            .corner_radius = 10,
        }, .{
            HeaderRow{},
            ui.scroll("response-scroll", .{ .height = 380 }, .{
                HeadersBlock{},
                BodyBlock{},
                TruncatedNote{},
            }),
        }));
    }
};

const HeaderRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.hstack(.{ .gap = 8, .alignment = .center }, .{
            ui.text("Response", .{
                .size = 12,
                .weight = .medium,
                .color = colors.muted,
            }),
            ui.spacer(),
            Button{
                .label = "Copy body",
                .variant = .secondary,
                .size = .small,
                .enabled = s.pending_body_len > 0 and AppState.isText(s.pending_body_buf[0..s.pending_body_len]),
                .on_click_handler = cx.command(AppState.copyBody),
            },
        }));
    }
};

const HeadersBlock = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        if (s.pending_headers_len == 0) return;

        cx.render(ui.box(.{
            .fill_width = true,
            .direction = .column,
            .gap = 4,
        }, .{
            ui.text("Headers", .{
                .size = 12,
                .weight = .medium,
                .color = colors.muted,
            }),
            ui.text(s.pending_headers_buf[0..s.pending_headers_len], .{
                .size = 12,
                .color = colors.text,
                .wrap = .newlines,
            }),
        }));
    }
};

const BodyBlock = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        if (s.pending_body_len == 0) return;

        const full = s.pending_body_buf[0..s.pending_body_len];
        if (!AppState.isText(full)) {
            cx.render(ui.textFmt("{d} bytes (binary)", .{full.len}, .{
                .size = 13,
                .color = colors.muted,
            }));
            return;
        }

        const preview = full[0..@min(full.len, state_mod.preview_cap)];
        cx.render(ui.text(preview, .{
            .size = 13,
            .color = colors.text,
            .wrap = .newlines,
        }));
    }
};

const TruncatedNote = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        if (s.pending_body_len <= state_mod.preview_cap) return;

        var shown_buf: [16]u8 = undefined;
        var total_buf: [16]u8 = undefined;
        cx.render(ui.textFmt("truncated — showing first {s} of {s}", .{
            state_mod.formatBytes(&shown_buf, state_mod.preview_cap),
            state_mod.formatBytes(&total_buf, s.pending_body_len),
        }, .{
            .size = 12,
            .color = colors.muted,
        }));
    }
};
