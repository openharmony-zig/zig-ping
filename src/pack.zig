const std = @import("std");
const net = std.net;
const os = std.os;
const time = std.time;
const print = std.debug.print;
const ArrayList = std.ArrayList;

pub const ICMPHeader = packed struct {
    type: u8,
    code: u8,
    checksum: u16,
    id: u16,
    sequence: u16,

    const Self = @This();

    pub fn init(icmp_type: u8, code: u8, id: u16, sequence: u16) Self {
        return Self{
            .type = icmp_type,
            .code = code,
            .checksum = 0,
            .id = std.mem.nativeToBig(u16, id),
            .sequence = std.mem.nativeToBig(u16, sequence),
        };
    }
};

pub const ICMP_ECHO_REQUEST: u8 = 8;
pub const ICMP_ECHO_REPLY: u8 = 0;

pub const IPHeader = packed struct {
    version_ihl: u8,
    tos: u8,
    total_length: u16,
    id: u16,
    flags_fragment: u16,
    ttl: u8,
    protocol: u8,
    checksum: u16,
    src_addr: u32,
    dst_addr: u32,

    pub fn getHeaderLength(self: *const IPHeader) u8 {
        return (self.version_ihl & 0x0F) * 4;
    }
};

pub fn calculateChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    while (i < data.len - 1) : (i += 2) {
        const word = (@as(u16, data[i]) << 8) | data[i + 1];
        sum += word;
    }

    if (i < data.len) {
        sum += @as(u16, data[i]) << 8;
    }

    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return ~@as(u16, @truncate(sum));
}

pub const ICMPPacket = struct {
    header: ICMPHeader,
    data: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, id: u16, sequence: u16) !Self {
        // Generate payload data with pattern (common practice for ping)
        var payload_buffer: [1024]u8 = undefined;
        const actual_size = 1024;

        // Fill payload with pattern data
        for (0..actual_size) |i| {
            payload_buffer[i] = @as(u8, @intCast(i % 256));
        }

        const payload = try allocator.dupe(u8, payload_buffer[0..actual_size]);

        return Self{
            .header = ICMPHeader.init(ICMP_ECHO_REQUEST, 0, id, sequence),
            .data = payload,
            .allocator = allocator,
        };
    }

    pub fn serialize(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        const packet_size = @sizeOf(ICMPHeader) + self.data.len;
        var packet = try allocator.alloc(u8, packet_size);

        const header_bytes = std.mem.asBytes(&self.header);
        @memcpy(packet[0..@sizeOf(ICMPHeader)], header_bytes);

        if (self.data.len > 0) {
            @memcpy(packet[@sizeOf(ICMPHeader)..], self.data);
        }

        const checksum = calculateChecksum(packet);
        std.mem.writeInt(u16, packet[2..4], checksum, .big);

        return packet;
    }

    /// Parse ICMP packet from raw bytes
    pub fn parse(allocator: std.mem.Allocator, raw_data: []const u8) !Self {
        if (raw_data.len < @sizeOf(ICMPHeader)) {
            return error.InvalidPacket;
        }

        const header = std.mem.bytesAsValue(ICMPHeader, raw_data[0..@sizeOf(ICMPHeader)]);
        const data = raw_data[@sizeOf(ICMPHeader)..];

        return Self{
            .header = header.*,
            .data = data,
            .allocator = allocator,
        };
    }

    /// Verify ICMP packet checksum
    pub fn verifyChecksum(self: *const Self) bool {
        const packet_size = @sizeOf(ICMPHeader) + self.data.len;
        var packet = self.allocator.alloc(u8, packet_size) catch return false;
        defer self.allocator.free(packet);

        const header_bytes = std.mem.asBytes(&self.header);
        @memcpy(packet[0..@sizeOf(ICMPHeader)], header_bytes);

        if (self.data.len > 0) {
            @memcpy(packet[@sizeOf(ICMPHeader)..], self.data);
        }

        const calculated_checksum = calculateChecksum(packet);
        return calculated_checksum == 0; // Checksum should be 0 when valid
    }
};

/// Parse ICMP header from raw bytes
pub fn parseICMPHeader(raw_data: []const u8) !ICMPHeader {
    if (raw_data.len < @sizeOf(ICMPHeader)) {
        return error.InvalidPacket;
    }

    return std.mem.bytesAsValue(ICMPHeader, raw_data[0..@sizeOf(ICMPHeader)]).*;
}

/// Parse IP header from raw bytes
pub fn parseIPHeader(raw_data: []const u8) !IPHeader {
    if (raw_data.len < @sizeOf(IPHeader)) {
        return error.InvalidPacket;
    }

    return std.mem.bytesAsValue(IPHeader, raw_data[0..@sizeOf(IPHeader)]).*;
}

/// Extract ICMP data from IP packet
pub fn extractICMPFromIP(raw_data: []const u8) ![]const u8 {
    const ip_header = try parseIPHeader(raw_data);
    const ip_header_len = ip_header.getHeaderLength();

    if (raw_data.len < ip_header_len) {
        return error.InvalidPacket;
    }

    return raw_data[ip_header_len..];
}
