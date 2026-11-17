# Development

The required toolchain version is recorded in `build.zig.zon` and pinned in
CI. Use the existing build steps; no separate test runner is needed.

## Offline checks

```sh
zig build check test stress -Doptimize=safe
zig build examples bench-build -Doptimize=fast
```

`check` checks formatting and compiles all entry points, including integration
tests, without executing network code. `test` runs unit and regression tests;
`stress` also runs deterministic bounded stress tests and depends on `test`.
`examples` and `bench-build` compile and install without running applications.

Use `-Dtest-filter=substring` to select tests. Format intentional source edits
with `zig fmt` before running checks.

CI runs offline tests and builds natively on Linux x64, Windows x64, and macOS
ARM64. It does not run socket integration tests or public-DHT applications.
Cross-compilation alone is not runtime verification.

## Network validation

```sh
zig build integration -Doptimize=safe
```

Integration tests open real UDP and TCP sockets. Run them only on the
designated test host. Likewise, execute the spider, lookup, and UDP server
only there during project validation. Give application runs an explicit time
limit and confirm that processes have exited afterward. Do not run these
network steps as part of local offline checks.

## Benchmarks and artifacts

```sh
zig build bench -Doptimize=fast
```

This runs offline benchmarks and writes `out/benchmark.csv` and
`out/benchmark.log`. The [benchmark guide](../bench/README.md) describes
fixtures, allocation accounting, filtering, and reproducible comparisons.

Store test logs, benchmark comparisons, review reports, and temporary
validation scripts in this project's ignored `out/` directory. Build outputs
and tool caches may remain in their standard directories. Keep generated
results out of committed documentation.
