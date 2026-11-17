# Offline benchmarks

Build with `zig build bench-build -Doptimize=fast`, then run the installed
`dht-bench` executable. Stdout contains CSV; stderr contains human-readable
statistics. `zig build bench -Doptimize=fast` writes the CSV to
`out/benchmark.csv` and statistics to `out/benchmark.log`. No benchmark opens a
socket. Save test logs, comparison data, and reports under the project's ignored
`out/` directory as well.

Fixtures use the fixed seed `0x646874`. Every closest-node sample cycles through
256 targets; each routing-update/churn sample visits all 5,000 contacts.
Large routing cases use 10 samples in one round; other cases use 20 samples
in each of three rounds. `--case=routing_update_5000` selects one case.

Cases cover parsing, KRPC ping, a find_node response with 512 known contacts,
closest 8 of 512, closest 64 of 5,000, crawler closest 8 of 5,000,
updating existing contacts in standard and crawler tables,
removing/reinserting contacts, constructing a 512-contact table, transaction
churn, and assembling/verifying 16 KiB of metadata. KRPC cases include server
setup amortized over each sample. Routing fixtures are built outside timing.
Allocation accounting therefore excludes routing fixture construction except
in `routing_build_512`. Use `--memory` to separately report live requested
allocation bytes for 512- and 5,000-contact standard/crawler tables, including
their indexes and spare capacity. These are allocator requests, not process RSS.

The large update/churn batches start with one repeat and calibrate upward to
the minimum sample duration; each repeat still visits every contact. New-table
construction uses 10 samples in one round as well. This keeps slow baselines
bounded while measuring the same full fixture in faster versions.

For a before/after comparison:

1. Preserve the baseline sources and build both versions with the same Zig,
   optimization mode, target, benchmark source, and dependency revision.
2. Finish builds and tests before measuring. Run the two executables serially
   in the order before/after, after/before, before/after.
3. Save stdout and stderr for each process. Compare the median of the three
   `mean_ns` values per case, and inspect `cv` and batch percentiles for noise.
4. Report latency reduction as `100 * (1 - after / before)`. Small movements
   in unchanged cases are not evidence of an improvement.

Use `--allocations` for a separate allocation-accounting run; do not mix its
timings with normal runs. These microbenchmarks do not measure public DHT
throughput, metadata discovery rate, or long-running memory usage.
