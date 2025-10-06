const std = @import("std");
const napi = @import("napi");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const IPResolverError = error{
    InvalidIPFormat,
    ResolutionFailed,
    OutOfMemory,
};

pub const IPFamily = enum {
    ipv4,
    ipv6,
    auto,
};

pub fn isValidIP(ip_str: []const u8) bool {
    if (net.Address.parseIp4(ip_str, 0)) |_| {
        return true;
    } else |_| {}

    if (net.Address.parseIp6(ip_str, 0)) |_| {
        return true;
    } else |_| {}

    return false;
}

fn formatAddress(allocator: Allocator, addr: std.net.Address) ![]const u8 {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    switch (addr.any.family) {
        posix.AF.INET => {
            const bytes = std.mem.asBytes(&addr.in.sa.addr);
            _ = try writer.print("{}.{}.{}.{}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
        },
        posix.AF.INET6 => {
            _ = try addr.in6.format(&writer);
        },
        else => return error.UnsupportedFamily,
    }

    return try allocator.dupe(u8, writer.buffer);
}

fn isAddressFamily(addr: std.net.Address, family: IPFamily) bool {
    return switch (family) {
        .ipv4 => addr.any.family == posix.AF.INET,
        .ipv6 => addr.any.family == posix.AF.INET6,
        .auto => true,
    };
}

/// Resolve hostname to IP address string
pub fn resolveHostname(allocator: Allocator, hostname: []const u8, prefer: IPFamily) ![]const u8 {
    // Use std.net to resolve hostname
    const address_list = std.net.getAddressList(allocator, hostname, 0) catch {
        return napi.Error.fromReason("Failed to resolve hostname");
    };
    defer address_list.deinit();

    if (address_list.addrs.len == 0) {
        return napi.Error.fromReason("Resolve hostname's result is empty");
    }

    // If auto mode, return the first address
    if (prefer == .auto) {
        return try formatAddress(allocator, address_list.addrs[0]);
    }

    for (address_list.addrs) |addr| {
        if (isAddressFamily(addr, prefer)) {
            return try formatAddress(allocator, addr);
        }
    }

    return try formatAddress(allocator, address_list.addrs[0]);
}

/// Main function: get IP address string
/// If input is valid IP, return directly; otherwise try domain name resolution
pub fn getIPAddress(allocator: Allocator, input: []const u8, prefer: IPFamily) ![]const u8 {
    // First check if it is a valid IP address
    if (isValidIP(input)) {
        // If it is a valid IP, return a copy
        return try allocator.dupe(u8, input);
    }

    // Not a valid IP, try domain name resolution
    return try resolveHostname(allocator, input, prefer);
}

/// Remove port from IP address string (if exists)
pub fn removePort(input: []const u8) []const u8 {
    // IPv6 with port: [::1]:8080
    if (std.mem.startsWith(u8, input, "[")) {
        if (std.mem.indexOf(u8, input, "]:")) |pos| {
            return input[1..pos];
        }
        return input;
    }

    // IPv4 with port: 192.168.1.1:8080
    if (std.mem.lastIndexOf(u8, input, ":")) |pos| {
        const port_part = input[pos + 1 ..];
        if (std.fmt.parseInt(u16, port_part, 10)) |_| {
            return input[0..pos];
        } else |_| {}
    }

    return input;
}
