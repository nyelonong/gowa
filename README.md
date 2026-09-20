# Gowa

A GPU-accelerated HTTP client for macOS, written in Zig.

Gowa renders entirely on Metal via [Gooey](https://github.com/duanebester/gooey) and
speaks HTTP/1.1 + TLS through Zig's standard library (`std.http`) — zero external
dependencies, one ~8 MB binary.

## Features

- All HTTP/1.1 methods (GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS)
- Request body editor for body-carrying methods
- Follow-redirects toggle (off shows raw 3xx responses)
- Response status with canonical phrase, humanized size, and elapsed time
- Response headers and body view (16 kB preview cap), copy body to clipboard
- Requests run off the UI thread — the window never blocks

## Build and run

Requires Zig 0.16.0 (pinned via mise: `mise install`).

```sh
zig build run
```

## Tests

```sh
zig build test
```

## Project structure

| File | Role |
| --- | --- |
| `src/main.zig` | Entry point, process-global `Io`, render tree (request bar, status, response card) |
| `src/state.zig` | App state, async worker (`io.async` + `Io.Queue`), send/stop/drain lifecycle |
| `src/http.zig` | Pure transport: `parseUrl` + `fetch` over `std.http.Client`, unit-testable without UI |

## How the async engine works

1. `main` publishes the process `Io` (Zig 0.16's `std.process.Init.io`) as a module global.
2. **Send** stages the request (URL, body, redirect flag) into fixed buffers on the state, then
   launches `io.async(fetchWorker, ...)` and keeps the returned `std.Io.Future(void)`.
3. The worker allocates a fresh **arena** per request, performs the fetch, copies results into
   the staging buffers, and pushes a typed `WorkerResult` into a bounded `Io.Queue`.
   The arena's `deinit` frees everything from the request in one call.
4. The **render loop drains the queue** every frame (`cx.drainQueue`); the queue's internal
   synchronization is the happens-before edge, so no locks or atomics are needed.
5. Terminal results `await` the future (releasing Io task bookkeeping); **Stop** calls
   `Future.cancel`, which unwinds the worker at its next cancelable I/O call.
