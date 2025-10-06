const std = @import("std");
const napi = @import("napi");
const net = std.net;
const os = std.os;
const posix = std.posix;
const pack = @import("pack.zig");
const domain = @import("domain.zig");
const ArrayList = std.ArrayList;

const PingResult = struct {
    sequence: u16,
    rtt_ms: f64,
    success: bool,
    error_msg: ?[]const u8,
    ip_addr: []const u8,
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
    ip_version: []const u8,
};

fn ping_execute(_: napi.Env, config: PingConfig) !ArrayList(PingResult) {
    const allocator = std.heap.page_allocator;

    const ip_version = if (std.mem.eql(u8, config.config.ip_version, "ipv4")) domain.IPFamily.ipv4 else if (std.mem.eql(u8, config.config.ip_version, "ipv6")) domain.IPFamily.ipv6 else domain.IPFamily.auto;

    const target_ip = domain.getIPAddress(allocator, config.host, ip_version) catch {
        return napi.Error.fromReason("Failed to get IP address");
    };

    const target_addr = net.Address.parseIp(target_ip, 0) catch {
        return napi.Error.fromReason("Failed to parse IP address");
    };

    var results = ArrayList(PingResult).empty;

    if (target_addr.any.family != posix.AF.INET and target_addr.any.family != posix.AF.INET6) {
        return napi.Error.fromReason("IPv4 is not supported");
    }

    const socket: posix.socket_t = posix.socket(target_addr.any.family, posix.SOCK.DGRAM, posix.IPPROTO.ICMP) catch {
        return napi.Error.fromReason("Failed to create socket");
    };

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

        const packet_data = packet.serialize(allocator) catch {
            return napi.Error.fromReason("Failed to serialize ICMP packet");
        };
        const start_time = std.time.nanoTimestamp();
        _ = posix.sendto(socket, packet_data, 0, &target_addr.any, target_addr.getOsSockLen()) catch @panic("Failed to send data");

        const bytes_received = posix.recvfrom(socket, buffer[0..], 0, &addr, &addrlen) catch @panic("Failed to receive data");
        const end_time = std.time.nanoTimestamp();
        const rtt_ns = end_time - start_time;
        const rtt_ms = @as(f64, @floatFromInt(rtt_ns)) / 1_000_000.0;

        // Parse the received packet
        const icmp_data = pack.extractICMPFromIP(buffer[0..bytes_received]) catch {
            results.append(allocator, PingResult{
                .sequence = 1,
                .rtt_ms = rtt_ms,
                .success = false,
                .error_msg = "Failed to extract ICMP data from IP packet",
                .ip_addr = target_ip,
            }) catch @panic("Failed to append PingResult");
            continue;
        };

        const received_packet = pack.ICMPPacket.parse(allocator, icmp_data) catch {
            results.append(allocator, PingResult{
                .sequence = 1,
                .rtt_ms = rtt_ms,
                .success = false,
                .error_msg = "Failed to parse ICMP packet",
                .ip_addr = target_ip,
            }) catch @panic("Failed to append PingResult");
            continue;
        };

        // Verify checksum
        if (!received_packet.verifyChecksum()) {
            results.append(allocator, PingResult{
                .sequence = 1,
                .rtt_ms = rtt_ms,
                .success = false,
                .error_msg = "ICMP packet checksum verification failed",
                .ip_addr = target_ip,
            }) catch @panic("Failed to append PingResult");
            continue;
        }

        // Check if it's an echo reply
        const is_echo_reply = received_packet.header.type == pack.ICMP_ECHO_REPLY;
        const sequence_match = std.mem.nativeToBig(u16, received_packet.header.sequence) == index;

        results.append(allocator, PingResult{
            .sequence = 1,
            .rtt_ms = rtt_ms,
            .success = is_echo_reply and sequence_match,
            .error_msg = null,
            .ip_addr = target_ip,
        }) catch @panic("Failed to append PingResult");
    }

    return results;
}

const PingConfig = struct {
    host: []const u8,
    config: InnerPingOption,
};

pub fn ping(env: napi.Env, host: []const u8, config: ?PingOption) napi.Promise {
    var options = InnerPingOption{
        .count = 10,
        .interval_ms = 1000,
        .timeout_ms = 5000,
        .ip_version = "ipv4",
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
            options.ip_version = ip_version;
        }
    }

    const worker = napi.Worker(env, .{
        .data = PingConfig{
            .host = host,
            .config = options,
        },
        .Execute = ping_execute,
    });

    return worker.AsyncQueue();
}

comptime {
    napi.NODE_API_MODULE("zig_ping", @This());
}
