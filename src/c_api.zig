//! C API implementation for libzmosh embedding in native apps.
const std = @import("std");
const udp = @import("udp.zig");
const crypto = @import("crypto.zig");
const link_mod = @import("link.zig");
const wire = @import("wire.zig");

pub const Status = enum(c_int) {
    ok = 0,
    err_resolve = 1,
    err_socket = 2,
    err_invalid_key = 3,
    err_disconnected = 4,
    err_dead = 5,
    err_poll = 6,
    err_null = 7,
    err_send = 8,
    err_too_large = 9,
};

pub const State = enum(c_int) {
    connected = 0,
    disconnected = 1,
    dead = 2,
};

pub const OutputFn = *const fn (?*anyopaque, [*]const u8, u32) callconv(.c) void;
pub const StateFn = *const fn (?*anyopaque, State) callconv(.c) void;
pub const SessionEndFn = *const fn (?*anyopaque) callconv(.c) void;

pub const Session = struct {
    alloc: std.mem.Allocator,
    link: link_mod.Link,
    output_cb: OutputFn,
    state_cb: ?StateFn,
    end_cb: ?SessionEndFn,
    ctx: ?*anyopaque,
    last_state: udp.PeerState,
    session_ended: bool,
};

fn nanoNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

// Bionic compatibility shim: musl calls __errno_location(), Android exports __errno()
extern "c" fn __errno() *c_int;

export fn __errno_location() *c_int {
    return __errno();
}

export fn zmosh_connect(
    host: ?[*:0]const u8,
    port: u16,
    key_base64: ?[*:0]const u8,
    rows: u16,
    cols: u16,
    output_cb: ?OutputFn,
    state_cb: ?StateFn,
    end_cb: ?SessionEndFn,
    ctx: ?*anyopaque,
    status: ?*Status,
) ?*Session {
    const set_status = struct {
        fn f(s: ?*Status, v: Status) void {
            if (s) |p| p.* = v;
        }
    }.f;

    const host_str = host orelse {
        set_status(status, .err_null);
        return null;
    };
    const key_str = key_base64 orelse {
        set_status(status, .err_null);
        return null;
    };
    const cb = output_cb orelse {
        set_status(status, .err_null);
        return null;
    };

    const key = crypto.keyFromBase64(std.mem.span(key_str)) catch {
        set_status(status, .err_invalid_key);
        return null;
    };

    const addr = udp.Address.resolve(std.mem.span(host_str), port) catch {
        set_status(status, .err_resolve);
        return null;
    };

    var sock = udp.UdpSocket.bindClient(addr) catch {
        set_status(status, .err_socket);
        return null;
    };

    const alloc = std.heap.c_allocator;
    const now = nanoNow();
    var link = link_mod.Link.init(alloc, sock, key, .to_server, now) catch {
        sock.close();
        set_status(status, .err_socket);
        return null;
    };
    link.peer.addr = addr;

    const size = wire.encodeSize(.{ .rows = rows, .cols = cols });
    link.enqueue(.Init, &size) catch {
        link.deinit();
        set_status(status, .err_send);
        return null;
    };

    const session = alloc.create(Session) catch {
        link.deinit();
        set_status(status, .err_socket);
        return null;
    };

    session.* = .{
        .alloc = alloc,
        .link = link,
        .output_cb = cb,
        .state_cb = state_cb,
        .end_cb = end_cb,
        .ctx = ctx,
        .last_state = .connected,
        .session_ended = false,
    };

    set_status(status, .ok);
    return session;
}

export fn zmosh_get_fd(session: ?*const Session) c_int {
    const s = session orelse return -1;
    return s.link.socket.fd;
}

export fn zmosh_poll(session: ?*Session) Status {
    const s = session orelse return .err_null;
    if (s.session_ended) return .ok;

    const now = nanoNow();

    // Recv datagrams
    s.link.receive(now) catch |err| switch (err) {
        error.WouldBlock, error.Interrupted => {},
        else => return .err_poll,
    };

    // Process ordered records
    while (s.link.recv.peek()) |payload| {
        const msg = wire.decode(payload) catch break;
        switch (msg.tag) {
            .Output => {
                s.output_cb(s.ctx, msg.data.ptr, @intCast(msg.data.len));
            },
            .SessionEnd => {
                s.session_ended = true;
                if (s.end_cb) |cb| cb(s.ctx);
                s.link.recv.pop();
                return .ok;
            },
            else => {},
        }
        s.link.recv.pop();
    }

    // Update link state and send heartbeats / ACKs
    s.link.tick(now) catch |err| switch (err) {
        error.PeerTimeout => {
            if (s.last_state != .dead) {
                s.last_state = .dead;
                if (s.state_cb) |cb| cb(s.ctx, .dead);
            }
            return .err_dead;
        },
        else => {},
    };

    const peer_state = s.link.peer.updateState(now, .{ .alive_timeout_ms = 15_000 });
    const mapped: State = switch (peer_state) {
        .connected => .connected,
        .disconnected => .disconnected,
        .dead => .dead,
    };
    if (peer_state != s.last_state) {
        s.last_state = peer_state;
        if (s.state_cb) |cb| cb(s.ctx, mapped);
    }

    return .ok;
}

const max_input_len = 8192;

export fn zmosh_send_input(session: ?*Session, data: ?[*]const u8, len: u32) Status {
    const s = session orelse return .err_null;
    const d = data orelse return .err_null;
    if (len == 0) return .ok;
    if (len > max_input_len) return .err_too_large;

    s.link.enqueue(.Input, d[0..len]) catch return .err_send;
    const now = nanoNow();
    s.link.tick(now) catch {};
    return .ok;
}

export fn zmosh_resize(session: ?*Session, rows: u16, cols: u16) Status {
    const s = session orelse return .err_null;
    const size = wire.encodeSize(.{ .rows = rows, .cols = cols });
    s.link.enqueue(.Resize, &size) catch return .err_send;
    const now = nanoNow();
    s.link.tick(now) catch {};
    return .ok;
}

export fn zmosh_disconnect(session: ?*Session) void {
    const s = session orelse return;
    s.link.enqueue(.Detach, "") catch {};
    const now = nanoNow();
    s.link.tick(now) catch {};
    s.link.deinit();
    s.alloc.destroy(s);
}
