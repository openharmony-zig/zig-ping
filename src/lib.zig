const std = @import("std");
const napi = @import("napi");
const net = std.Io.net;
const posix = std.posix;
const pack = @import("pack.zig");
const domain = @import("domain.zig");
const ArrayList = std.ArrayList;

const PosixAddress = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
};

const ParsedAddress = struct {
    storage: PosixAddress,
    len: posix.socklen_t,
    family: posix.sa_family_t,
};

fn parseIPAddress(ip_addr: []const u8) !ParsedAddress {
    const addr = net.IpAddress.parse(ip_addr, 0) catch return error.InvalidAddress;

    switch (addr) {
        .ip4 => |ip4| {
            const storage = PosixAddress{
                .in = .{
                    .port = std.mem.nativeToBig(u16, ip4.port),
                    .addr = @bitCast(ip4.bytes),
                },
            };
            return .{
                .storage = storage,
                .len = @sizeOf(posix.sockaddr.in),
                .family = posix.AF.INET,
            };
        },
        .ip6 => |ip6| {
            const storage = PosixAddress{
                .in6 = .{
                    .port = std.mem.nativeToBig(u16, ip6.port),
                    .flowinfo = ip6.flow,
                    .addr = ip6.bytes,
                    .scope_id = ip6.interface.index,
                },
            };
            return .{
                .storage = storage,
                .len = @sizeOf(posix.sockaddr.in6),
                .family = posix.AF.INET6,
            };
        },
    }
}

fn monotonicNanoTimestamp() i128 {
    var ts: posix.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) {
        @panic("Failed to get monotonic clock");
    }
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

const PingResult = struct {
    sequence: u16,
    rtt_ms: f64,
    success: bool,
    error_msg: ?[]const u8,
    ip_addr: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.error_msg) |msg| {
            allocator.free(msg);
        }
        allocator.free(self.ip_addr);
    }
};

const PingOption = struct {
    count: ?u32,
    interval_ms: ?u32,
    timeout_ms: ?u32,
    ip_version: ?[]const u8,
};

const InnerPingOption = struct {
    count: u32,
    interval_ms: u32,
    timeout_ms: u32,
    ip_version: domain.IPFamily,
};

fn appendPingResult(
    allocator: std.mem.Allocator,
    results: *ArrayList(PingResult),
    sequence: u16,
    rtt_ms: f64,
    success: bool,
    error_msg: ?[]const u8,
    ip_addr: []const u8,
) !void {
    const owned_error = if (error_msg) |msg| try allocator.dupe(u8, msg) else null;
    errdefer if (owned_error) |msg| allocator.free(msg);

    const owned_ip_addr = try allocator.dupe(u8, ip_addr);
    errdefer allocator.free(owned_ip_addr);

    try results.append(allocator, PingResult{
        .sequence = sequence,
        .rtt_ms = rtt_ms,
        .success = success,
        .error_msg = owned_error,
        .ip_addr = owned_ip_addr,
    });
}

fn deinitPartialPingResults(allocator: std.mem.Allocator, results: *ArrayList(PingResult)) void {
    for (results.items) |*result| {
        result.deinit(allocator);
    }
    results.deinit(allocator);
}

fn ping_execute(config: PingConfig) !ArrayList(PingResult) {
    const allocator = napi.globalAllocator();

    const target_ip = domain.getIPAddress(allocator, config.host, config.config.ip_version) catch {
        return napi.Error.fromReason("Failed to get IP address");
    };
    defer allocator.free(target_ip);

    const target_addr = parseIPAddress(target_ip) catch {
        return napi.Error.fromReason("Failed to parse IP address");
    };

    var results = ArrayList(PingResult).empty;
    errdefer deinitPartialPingResults(allocator, &results);

    if (target_addr.family != posix.AF.INET and target_addr.family != posix.AF.INET6) {
        return napi.Error.fromReason("IP address family is not supported");
    }

    const protocol: u32 = if (target_addr.family == posix.AF.INET6) @intCast(posix.IPPROTO.ICMPV6) else @intCast(posix.IPPROTO.ICMP);
    const socket_rc = std.c.socket(@intCast(target_addr.family), @intCast(posix.SOCK.DGRAM), protocol);
    if (socket_rc < 0) {
        return napi.Error.fromReason("Failed to create socket");
    }
    const socket: posix.socket_t = socket_rc;
    defer _ = std.c.close(socket);

    const timeout_ms = config.config.timeout_ms;
    const timeout = posix.timeval{
        .sec = @intCast((timeout_ms / 1000)),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };

    _ = posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {
        return napi.Error.fromReason("Failed to set socket timeout");
    };

    var buffer: [2048]u8 = undefined;
    var addr: posix.sockaddr = undefined;
    var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr);

    for (0..config.config.count) |index| {
        // Create ICMP packet with auto-generated payload
        var packet = pack.ICMPPacket.init(allocator, 1, @intCast(index)) catch @panic("Failed to initialize ICMP packet");
        const echo_reply_type = if (target_addr.family == posix.AF.INET6) pack.ICMPV6_ECHO_REPLY else pack.ICMP_ECHO_REPLY;
        if (target_addr.family == posix.AF.INET6) {
            packet.header.type = pack.ICMPV6_ECHO_REQUEST;
        }
        defer allocator.free(packet.data);

        const packet_data = packet.serialize(allocator) catch {
            return napi.Error.fromReason("Failed to serialize ICMP packet");
        };
        defer allocator.free(packet_data);

        const start_time = monotonicNanoTimestamp();
        if (std.c.sendto(socket, packet_data.ptr, packet_data.len, 0, &target_addr.storage.any, target_addr.len) < 0) {
            @panic("Failed to send data");
        }

        const recv_rc = std.c.recvfrom(socket, buffer[0..].ptr, buffer.len, 0, &addr, &addrlen);
        if (recv_rc < 0) {
            @panic("Failed to receive data");
        }
        const bytes_received: usize = @intCast(recv_rc);
        const end_time = monotonicNanoTimestamp();
        const rtt_ns = end_time - start_time;
        const rtt_ms = @as(f64, @floatFromInt(rtt_ns)) / 1_000_000.0;

        // Parse the received packet
        const icmp_data = if (target_addr.family == posix.AF.INET6)
            buffer[0..bytes_received]
        else
            pack.extractICMPFromIP(buffer[0..bytes_received]) catch {
                appendPingResult(
                    allocator,
                    &results,
                    1,
                    rtt_ms,
                    false,
                    "Failed to extract ICMP data from IP packet",
                    target_ip,
                ) catch @panic("Failed to append PingResult");
                continue;
            };

        const received_packet = pack.ICMPPacket.parse(allocator, icmp_data) catch {
            appendPingResult(
                allocator,
                &results,
                1,
                rtt_ms,
                false,
                "Failed to parse ICMP packet",
                target_ip,
            ) catch @panic("Failed to append PingResult");
            continue;
        };

        // Verify checksum
        if (target_addr.family == posix.AF.INET and !received_packet.verifyChecksum()) {
            appendPingResult(
                allocator,
                &results,
                1,
                rtt_ms,
                false,
                "ICMP packet checksum verification failed",
                target_ip,
            ) catch @panic("Failed to append PingResult");
            continue;
        }

        // Check if it's an echo reply
        const is_echo_reply = received_packet.header.type == echo_reply_type;
        const sequence_match = std.mem.nativeToBig(u16, received_packet.header.sequence) == index;

        appendPingResult(
            allocator,
            &results,
            1,
            rtt_ms,
            is_echo_reply and sequence_match,
            null,
            target_ip,
        ) catch @panic("Failed to append PingResult");
    }

    return results;
}

const PingConfig = struct {
    host: []const u8,
    config: InnerPingOption,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
    }
};

pub fn ping(host: []const u8, config: ?PingOption) napi.Async(ArrayList(PingResult), .thread) {
    var options = InnerPingOption{
        .count = 10,
        .interval_ms = 1000,
        .timeout_ms = 5000,
        .ip_version = .ipv4,
    };

    if (config) |c| {
        if (c.count) |count| {
            options.count = count;
        }
        if (c.interval_ms) |interval_ms| {
            options.interval_ms = interval_ms;
        }
        if (c.timeout_ms) |timeout_ms| {
            options.timeout_ms = timeout_ms;
        }
        if (c.ip_version) |ip_version| {
            defer napi.globalAllocator().free(ip_version);
            options.ip_version = if (std.mem.eql(u8, ip_version, "ipv4"))
                .ipv4
            else if (std.mem.eql(u8, ip_version, "ipv6"))
                .ipv6
            else
                .auto;
        }
    }

    return napi.Async(ArrayList(PingResult), .thread).from(PingConfig{
        .host = host,
        .config = options,
    }, ping_execute);
}

comptime {
    napi.NODE_API_MODULE("zig_ping", @This());
}
