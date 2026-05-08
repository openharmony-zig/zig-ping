const std = @import("std");
const napi = @import("napi");
const net = std.Io.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const PosixAddress = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
};

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
    if (net.IpAddress.parseIp4(ip_str, 0)) |_| {
        return true;
    } else |_| {}

    if (net.IpAddress.parseIp6(ip_str, 0)) |_| {
        return true;
    } else |_| {}

    return false;
}

fn formatSockaddr(allocator: Allocator, addr: *const posix.sockaddr) ![]const u8 {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const storage: *const PosixAddress = @ptrCast(@alignCast(addr));

    switch (addr.family) {
        posix.AF.INET => {
            const bytes: [4]u8 = @bitCast(storage.in.addr);
            _ = try writer.print("{}.{}.{}.{}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
        },
        posix.AF.INET6 => {
            const ip6 = net.Ip6Address.Unresolved{
                .bytes = storage.in6.addr,
                .interface_name = null,
            };
            _ = try ip6.format(&writer);
        },
        else => return error.UnsupportedFamily,
    }

    return try allocator.dupe(u8, writer.buffered());
}

fn isAddressFamily(addr: *const posix.sockaddr, family: IPFamily) bool {
    return switch (family) {
        .ipv4 => addr.family == posix.AF.INET,
        .ipv6 => addr.family == posix.AF.INET6,
        .auto => true,
    };
}

/// Resolve hostname to IP address string
pub fn resolveHostname(allocator: Allocator, hostname: []const u8, prefer: IPFamily) ![]const u8 {
    const hostname_z = try allocator.dupeZ(u8, hostname);
    defer allocator.free(hostname_z);

    const family: i32 = switch (prefer) {
        .ipv4 => @intCast(posix.AF.INET),
        .ipv6 => @intCast(posix.AF.INET6),
        .auto => @intCast(posix.AF.UNSPEC),
    };
    const hints = std.c.addrinfo{
        .flags = .{},
        .family = family,
        .socktype = @intCast(posix.SOCK.DGRAM),
        .protocol = 0,
        .addrlen = 0,
        .addr = null,
        .canonname = null,
        .next = null,
    };

    var result: ?*std.c.addrinfo = null;
    if (@intFromEnum(std.c.getaddrinfo(hostname_z, null, &hints, &result)) != 0) {
        return napi.Error.fromReason("Failed to resolve hostname");
    }
    defer if (result) |res| std.c.freeaddrinfo(res);

    var first_addr: ?*posix.sockaddr = null;
    var item = result;
    while (item) |info| : (item = info.next) {
        const addr = info.addr orelse continue;
        if (first_addr == null) {
            first_addr = addr;
        }
        if (isAddressFamily(addr, prefer)) {
            return try formatSockaddr(allocator, addr);
        }
    }

    if (first_addr) |addr| {
        return try formatSockaddr(allocator, addr);
    } else {
        return napi.Error.fromReason("Resolve hostname's result is empty");
    }
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
