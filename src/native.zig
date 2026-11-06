//! Native IPC translation bridging remote zmosh wire protocol to zmx daemon IPC.
const std = @import("std");
const zmx = @import("libzmx");
const wire = @import("wire.zig");

/// Validate the entire remote record before admitting it to native IPC.
pub fn appendNative(alloc: std.mem.Allocator, out: *std.ArrayList(u8), msg: wire.Message) !void {
    switch (msg.tag) {
        .Input => try zmx.ipc.appendMessage(alloc, out, .Input, msg.data),
        .Init, .Resize => {
            const size = try wire.decodeSize(msg.data);
            const native_size = zmx.ipc.Resize{
                .rows = size.rows,
                .cols = size.cols,
            };
            try zmx.ipc.appendMessage(alloc, out, if (msg.tag == .Init) .Init else .Resize, std.mem.asBytes(&native_size));
        },
        .Detach => {
            if (msg.data.len != 0) return error.InvalidLength;
            try zmx.ipc.appendMessage(alloc, out, .Detach, "");
        },
        .Output, .SessionEnd => return error.ForbiddenMessage,
    }
}

/// A bounded native decoder: reject the length as soon as the header arrives.
/// Read only `remaining()` bytes to avoid buffering a second frame behind a
/// maximum-sized snapshot. The caller consumes a frame before reading more.
pub const NativeFrame = struct {
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *NativeFrame, alloc: std.mem.Allocator) void {
        self.bytes.deinit(alloc);
    }

    pub fn remaining(self: *const NativeFrame) !usize {
        const size = @sizeOf(zmx.ipc.Header);
        if (self.bytes.items.len < size) return size - self.bytes.items.len;
        const h = std.mem.bytesToValue(zmx.ipc.Header, self.bytes.items[0..size]);
        if (h.len > wire.max_payload) return error.NativeFrameTooLarge;
        return size + @as(usize, h.len) - self.bytes.items.len;
    }

    pub fn append(self: *NativeFrame, alloc: std.mem.Allocator, data: []const u8) !void {
        if (data.len > try self.remaining()) return error.InvalidLength;
        try self.bytes.appendSlice(alloc, data);
        _ = try self.remaining();
    }

    pub fn message(self: *const NativeFrame) !?zmx.ipc.SocketMsg {
        if (try self.remaining() != 0) return null;
        const size = @sizeOf(zmx.ipc.Header);
        return .{ .header = std.mem.bytesToValue(zmx.ipc.Header, self.bytes.items[0..size]), .payload = self.bytes.items[size..] };
    }

    pub fn clear(self: *NativeFrame) void {
        self.bytes.clearRetainingCapacity();
    }
};

test "remote terminal end cannot become native Switch" {
    try std.testing.expectEqual(@as(u8, 11), @backingInt(zmx.ipc.Tag.Switch));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectError(error.ForbiddenMessage, appendNative(std.testing.allocator, &out, .{ .tag = .SessionEnd, .data = "" }));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "remote size translates to native encoding" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const data = wire.encodeSize(.{ .rows = 31, .cols = 97 });
    try appendNative(std.testing.allocator, &out, .{ .tag = .Init, .data = &data });
    const h = std.mem.bytesToValue(zmx.ipc.Header, out.items[0..8]);
    try std.testing.expectEqual(zmx.ipc.Tag.Init, h.tag);
    try std.testing.expectEqual(@as(u32, 8), h.len);
    const size = std.mem.bytesToValue(zmx.ipc.Resize, out.items[8..16]);
    try std.testing.expectEqual(@as(u16, 31), size.rows);
    try std.testing.expectEqual(@as(u16, 97), size.cols);
    try std.testing.expectEqual(@as(u16, 0), size.xpixel);
    try std.testing.expectEqual(@as(usize, 16), out.items.len);
}

test "native frame length is bounded before reading payload" {
    for ([_]u32{ wire.max_payload - 1, wire.max_payload, wire.max_payload + 1 }) |len| {
        var frame: NativeFrame = .{};
        defer frame.deinit(std.testing.allocator);
        const h = zmx.ipc.Header{ .tag = .Output, .len = len };
        if (len > wire.max_payload) {
            try std.testing.expectError(error.NativeFrameTooLarge, frame.append(std.testing.allocator, std.mem.asBytes(&h)));
        } else {
            try frame.append(std.testing.allocator, std.mem.asBytes(&h)[0..3]);
            try frame.append(std.testing.allocator, std.mem.asBytes(&h)[3..]);
            try std.testing.expectEqual(@as(usize, len), try frame.remaining());
            try std.testing.expectEqual(@as(usize, 8), frame.bytes.items.len);
        }
    }
}
