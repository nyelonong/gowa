const std = @import("std");

const gooey = @import("gooey");

pub const std_options = gooey.std_options;

const ui = gooey.ui;
const Cx = gooey.Cx;

const AppState = struct {};

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
        .padding = .{ .all = 32 },
        .gap = 8,
        .background = ui.Color.rgb8(17, 19, 24),
    }, .{
        ui.text("Gowa", .{
            .size = 32,
            .color = ui.Color.rgb8(235, 237, 240),
            .weight = .semibold,
        }),
        ui.text("A blazing fast HTTP client", .{
            .size = 14,
            .color = ui.Color.rgb8(140, 148, 160),
        }),
    }));
}
