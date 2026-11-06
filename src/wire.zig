//! The zmosh UDP remote protocol vocabulary and framing.
const std = @import("std");

pub const header_len = 8;
pub const max_payload = 64 * 1024 * 1024;
pub const max_buffer = max_payload + header_len;
pub const Tag = enum(u8) { Input = 0, Output = 1, Resize = 2, Detach = 3, Init = 7, SessionEnd = 11 };
pub const Message = struct { tag: Tag, data: []const u8 };

pub const Resize = struct {
    rows: u16,
    cols: u16,
};

// Preserve the pinned fork's eight-byte little-endian packed-header encoding,
// including zero padding, without exposing native tag assignments over UDP.
pub fn encode(tag: Tag, data: []const u8, out: []u8) ![]const u8 {
    if (data.len > max_payload or out.len < header_len + data.len) return error.MessageTooLarge;
    @memset(out[0..header_len], 0);
    out[0] = @backingInt(tag);
    std.mem.writeInt(u32, out[1..5], @intCast(data.len), .little);
    @memcpy(out[header_len..][0..data.len], data);
    return out[0 .. header_len + data.len];
}

pub fn decode(data: []const u8) !Message {
    if (data.len < header_len) return error.TruncatedMessage;
    const len = std.mem.readInt(u32, data[1..5], .little);
    if (len > max_payload or data.len != header_len + @as(usize, len)) return error.InvalidLength;
    if (!std.mem.eql(u8, data[5..8], &.{ 0, 0, 0 })) return error.InvalidPadding;
    return .{ .tag = std.enums.fromInt(Tag, data[0]) orelse return error.UnknownTag, .data = data[header_len..] };
}

pub fn encodeSize(size: anytype) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..2], size.rows, .little);
    std.mem.writeInt(u16, bytes[2..4], size.cols, .little);
    return bytes;
}

pub fn decodeSize(data: []const u8) !Resize {
    if (data.len != 4) return error.InvalidSize;
    const rows = std.mem.readInt(u16, data[0..2], .little);
    const cols = std.mem.readInt(u16, data[2..4], .little);
    if (rows == 0 or cols == 0) return error.InvalidSize;
    return .{ .rows = rows, .cols = cols };
}

test "wire size encoding and decoding" {
    const data = encodeSize(.{ .rows = 31, .cols = 97 });
    const size = try decodeSize(&data);
    try std.testing.expectEqual(@as(u16, 31), size.rows);
    try std.testing.expectEqual(@as(u16, 97), size.cols);
}

test "wire rejects unknown tags, truncation and trailing bytes" {
    var bytes: [64]u8 = undefined;
    const encoded = try encode(.Input, "hello", &bytes);
    try std.testing.expectEqualStrings("hello", (try decode(encoded)).data);
    try std.testing.expectError(error.InvalidLength, decode(encoded[0 .. encoded.len - 1]));
    bytes[0] = 99; // invalid tag
    try std.testing.expectError(error.UnknownTag, decode(encoded));
}
