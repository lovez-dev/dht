# dht

Discover peers and retrieve verified torrent metadata through the BitTorrent Mainline DHT. Recursive lookups, IPv4/IPv6 contacts, and announcement crawling.

## Installation

Clone the repository and build the applications:

```sh
git clone https://github.com/lovez-dev/dht.git
cd dht
zig build
```

This installs `dht-server` and `dht-spider` under `zig-out/bin` (with a `.exe` suffix on Windows). For library integration see [usage](docs/usage.md) and the [API contracts](docs/api.md).

## Usage

Crawl announcements and print fetched metadata as JSON:

```sh
zig build spider -- 6881
```

Find peers for a 40-character hexadecimal info hash:

```sh
zig build lookup -- d160b8d8ea35a5b4e52837468fc8f03d55cef1f7
```

Both commands connect to the public DHT and run until interrupted; discovery depends on live peer announcements. Compile the [examples](examples) without starting them with `zig build examples`. Run `zig build check test stress -Doptimize=safe` for offline checks and `zig build bench -Doptimize=fast` for benchmarks; see [development](docs/development.md) for details.

## License

[MIT](LICENSE)
