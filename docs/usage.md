# Usage

## Applications

`zig build` installs `dht-server` and `dht-spider` under `zig-out/bin/`.
`zig build examples` also installs `dht-lookup` and `dht-protocol`.
On Windows, executable names have the `.exe` suffix.

- `dht-spider [port]` crawls announcements and writes verified metadata as JSON
  to stdout. The default UDP port is 6881; diagnostics go to stderr.
- `dht-lookup <info-hash>` discovers peers for a 40-character hexadecimal hash.
  It uses an ephemeral UDP port and writes peer endpoints to stderr.
- `dht-server serve <port>` runs a low-level UDP KRPC responder. It does not
  run the bootstrap or maintenance loop provided by `StandardDht`.
- `dht-protocol` demonstrates bencode parsing without opening sockets.

The network applications run until interrupted. Metadata discovery depends on
peer announcements and availability; a running crawler may produce no metadata.

## Library integration

Add the package from the root of your application:

```sh
zig fetch --save=dht git+https://github.com/lovez-dev/dht.git
```

Commit the resulting dependency URL and hash in your `build.zig.zon`. Add the
module to your application's `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("dht", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "dht-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dht", .module = dependency.module("dht") }},
        }),
    });
    b.installArtifact(exe);
}
```

Use [the protocol example](../examples/protocol.zig) as `src/main.zig` for a
minimal offline consumer. Build with `zig build` and run the installed
`dht-example` executable. For peer discovery and metadata retrieval, see
[lookup](../examples/lookup.zig) and [spider](../examples/spider.zig).

## Configuration

`StandardDht` provides regular peer discovery; `Dht` enables announcement
crawling. Crawler mode advertises IDs near lookup targets and intentionally
does not reply to `find_node` queries. It is not a regular routing node.

Both configurations accept a port, `.udp4` or `.udp6` network, bootstrap
endpoints, callbacks, routing limits, and pending-query/lookup limits. The
default bootstrap endpoints are IPv4; supply compatible endpoints for IPv6.
Private endpoints are rejected by default. `allow_private_addresses` is
intended for controlled private networks.

Wire request/response capacities, worker limits, seen-cache limits, and
download deadlines are configured through `Wire.initWithConfig`. Use
`tryRequest` in DHT callbacks to avoid waiting for queue space.

See [API contracts](api.md) before integrating callbacks, shared allocators,
or background tasks.
