# API contracts

Import the public module with `@import("dht")`. It exports the high-level DHT
and Wire APIs plus protocol, routing, and transaction helpers. Internal fields
and source paths are not stable interfaces. Do not modify internal maps,
queues, counters, or routing views directly.

## Dht and StandardDht

- `init(allocator, io, config, random)` creates protocol state without binding a
  socket. On initialization failure, it releases allocations made so far.
  After success, the caller must call `deinit`.
- Keep the allocator, I/O backend, and random generator state valid until the
  node has finished using them. The node stores `random`, not a copy of its
  backing generator. Configuration is copied, but `bootstrap_nodes` and
  `context` still refer to application storage; keep them valid while used.
  `blocked_ips` is read during initialization.
- Call `run(io)` from one task using the same I/O backend supplied to `init`.
  Keep the node at a stable address. `run` binds and closes its own UDP socket
  on every return path; it does not free the node's protocol state.
- Only `getPeers`, `start`, `pause`, `stop`, and `stat` may be called from other
  threads while the loop runs. `bootstrap`, `findNode`, and `maintain` must run
  on the task driving the node. A shared allocator must support concurrent
  calls when producers can allocate alongside that task.
- `getPeers` copies the hash into a bounded queue. It can return `Stopped`,
  `LookupQueueFull`, or allocation errors. Success means admission, not lookup
  completion. Queued duplicate hashes are ignored. Responses arrive through
  `on_get_peers_response`; repeated peer callbacks are possible.
- Callbacks execute synchronously on the DHT loop. Keep them short, keep their
  context valid, and do not destroy the node from a callback. Hashes and
  endpoints are passed by value and may be retained.
- `pause` suspends receiving and maintenance. `start` resumes after a pause;
  it does not reverse `stop`. `stop` requests loop termination and does not
  join it. Wait for `run` and all external users before calling `deinit`.
  Cancellation through the supplied I/O also unwinds `run`.

## Wire

- `init` and `initWithConfig` prepare queues without opening sockets. Keep the
  allocator and I/O backend valid through cleanup. The random generator is
  used only to initialize the peer ID. Capacities and worker limits of zero
  are clamped to one. Set callbacks and context before starting `run`.
- One task dispatches `run`. Request submission, response retrieval, `stat`,
  and `stop` may run concurrently. Use an allocator suitable for concurrent
  calls, including calls by response consumers freeing metadata.
- `request` waits without cancellation when its queue is full. `tryRequest`
  returns `QueueFull` instead of waiting for space; it still acquires the queue
  mutex. Both copy the hash and endpoint, deduplicate admitted pairs, and can
  return `Stopped`, `InvalidPeer`, `Blacklisted`, or allocation errors.
- Consume the bounded response queue even when `on_metadata` is set. A full
  response queue delays workers and callbacks. `nextResponse` polls;
  `waitResponse` waits without cancellation; `waitResponseCancelable` also
  supports I/O cancellation. An empty stopped queue returns `null`.
- Each retrieved `Response.metadata` buffer must be freed by the caller using
  the allocator passed to Wire initialization. It stays valid independently
  of Wire after retrieval. Wire frees only buffers still in its queue.
- `on_metadata` receives a separate temporary view that is valid only for the
  callback duration. Copy it if needed later; do not free it. Callbacks may
  execute concurrently across download tasks, so synchronize shared context.
- `download_timeout_ms` covers the complete download, including response-queue
  backpressure. `stop` wakes queue waiters and prevents further dispatch; it
  does not immediately cancel every active download. Stop, join the dispatcher
  and external producers/consumers, then call `deinit`. `deinit` cancels and
  joins internal downloads before freeing queued data and maps.

## Protocol and routing helpers

| API | Allocation, data validity, and cleanup |
| --- | --- |
| `bencode.Parser.parse` | Allocates list/dictionary containers with the supplied allocator. Strings and dictionary keys refer directly to the input. Keep that input valid while reading the tree; call `Value.deinit` with the same allocator. Parse errors clean up partial containers. |
| `Value.get` | Returns a pointer into the tree, valid while that tree remains unchanged and allocated. |
| `RoutingTable` | The caller serializes access and calls `deinit`. `nodes.items` is a read-only view that may move on mutation; removal can change iteration order. `closest` copies results sorted by XOR distance into the caller's output buffer and returns a slice of it. |
| `Server` | The caller drives protocol operations on one task and calls `deinit`. Datagram handlers return a view of the caller's output buffer. Parsed-tree handlers use but do not free the supplied tree. Only `stats` is safe for concurrent monitoring; the protocol task publishes it with `refreshStats`. |
| `UdpService.bind` | Opens a socket while retaining pointers to the supplied server and random state. Keep both at stable addresses until the service stops. Cancel/join its loop before `deinit`, which closes the socket; separately free the server. |
| `MetadataAssembler` | `init` allocates assembly storage; `put` copies piece data. `finalize` returns a verified, independently allocated copy; free it with the assembler's allocator. `deinit` frees assembly storage on success or failure. |
| `peerwire.fetchMetadata` | Opens and closes its TCP connection internally, including error/cancellation paths. Returns verified metadata to be freed with the supplied allocator. Direct calls have no built-in total deadline; use a cancelable task or Wire for one. |
| `TransactionManager` | Copies registered pending records and packet bytes. The caller calls `deinit` and serializes access. Lists passed to `expire` or `retryOrExpire` receive copied records and must be freed with the manager's allocator. |
| `Blacklist` | Copies addresses/IPs into allocator-backed storage. The caller serializes access and calls `deinit`. |
| `integerToBytes` | Returns a slice into the caller's eight-byte output buffer without allocating. |

## Input and error constraints

Node IDs and info hashes are 20 bytes. The lookup application accepts their
40-character hexadecimal representation. Protocol endpoints use IPv4 or IPv6
with a nonzero port; public-network filtering is enabled by default.

The bencode parser rejects trailing data, duplicate dictionary keys,
noncanonical integers and string lengths, and nesting beyond `Parser.max_depth`.
Metadata pieces are 16 KiB except for the final piece; total size must be
positive and no greater than `peerwire.max_metadata_size`. Finalization
verifies the SHA-1 info hash and reports `InfoHashMismatch` on mismatch.

Initialization and protocol operations can return allocation, validation, I/O,
and cancellation errors. Release every successfully initialized object even
after later operations fail. Unless listed above, helpers provide no internal
thread synchronization.
