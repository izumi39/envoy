# xDS startup memory investigation

This branch preserves the original configuration, collection scripts, all memory samples,
all heap profiles, and GDB investigation. Only this README is new. Collector PID files and
routine collector logs are excluded. No fix is included.

## Conclusion and scope

The recorded run used [329dd51](https://github.com/envoyproxy/envoy/commit/329dd5106e758b7b24a65af51b8a28e3a0568af5).
With xDS unavailable and initial fetch timeouts disabled, main kept posting Date refresh
callbacks to registered worker dispatchers whose threads had not started. Memory samples,
heap profiles, and GDB queue observations support this mechanism. The experiment did not
run the process to OOM.

The proposed Date-only fix initializes each thread's Date cache immediately in its TLS
object constructor, then refreshes it with a local timer. This removes recurring posts to
unstarted workers, at the cost of per-thread timers and formatting. Asynchronous broadcasts
already do not guarantee simultaneous visibility across workers. Timer lifetime and startup
ordering need tests; the extra CPU cost has not been benchmarked.

The question for maintainers is whether to keep the fix Date-specific or address startup-time
periodic broadcasts more broadly. Other producers found by source review were not reproduced
in this experiment.

## Reproduce

The original environment was a Linux AArch64 Dev Container, an optimized symbol-bearing
binary using libc++, and four workers. The ELF build ID matched the commit above.
Use the [original configuration](../xds_debugging.yaml) and matching binary:

```bash
cd /workspaces/envoy
./bazel-bin/source/exe/envoy-static -c xds_debugging.yaml \
  --concurrency 4 --disable-hot-restart --log-level info
```

No control-plane service, application service, or traffic generator is needed. Ensure that
`control-plane:8080` does not reach a working xDS service. CDS and LDS have
`initial_fetch_timeout: 0s`. The static HCM creates the Date provider during configuration.
Admin is available at loopback port 19000.

The historical build invocation was not saved here. A suggested build is
`bazel build --config=clang -c opt //source/exe:envoy-static`, inside the development container.
Keep the original binary and its debug files before rebuilding: offline analysis requires
symbols matching the profiles.

## Original materials

- `envoy-memory-*.json`: all 212 original admin memory samples.
- `envoy-heap-*.heap`: all original compressed heap profiles.
- [collect_memory.sh](collect_memory.sh): collect immediately, then every five minutes.
- [collect_heap.sh](collect_heap.sh): collect immediately, then every thirty minutes.
- [GDB_INVESTIGATION_20260906.md](GDB_INVESTIGATION_20260906.md): commands, failed attempts,
  layout checks, observations, and limitations.
- [gdb_inspect.gdb](gdb_inspect.gdb): original inspection script.
- [gdb_initial_20260906.log](gdb_initial_20260906.log): original output, including errors
  and trailing whitespace.

Run collectors in the same container/network namespace as Envoy:

```bash
cd /workspaces/envoy
nohup bash xds_debug/collect_memory.sh > xds_debug/collect_memory.log 2>&1 < /dev/null &
echo $!
nohup bash xds_debug/collect_heap.sh > xds_debug/collect_heap.log 2>&1 < /dev/null &
echo $!
```

Record the printed collector PIDs and stop only those collectors when finished.
Heap collection requires a build exposing `/heap_dump` and has measurement overhead.

## Evidence

Allocated memory increased from 6,933,616 bytes at 2026-09-05 08:19:26 UTC to 192,326,400
bytes at 2026-09-06 01:52:25 UTC: approximately 176.80 MiB over 17.55 hours, or 0.168 MiB/min.
These are allocator values, not RSS. The interval includes heap collection and brief GDB pauses.
The endpoints are `envoy-memory-20260905-081926.json` and
`envoy-memory-20260906T015225Z-wwkNio.json`; intermediate raw samples are included.

Compare two profiles collected before the recorded GDB queue inspections using Google's pprof
and the original matching binary:

```bash
cd /workspaces/envoy
pprof -top -sample_index=inuse_space \
  -base xds_debug/envoy-heap-20260905T115141Z.heap \
  bazel-bin/source/exe/envoy-static \
  xds_debug/envoy-heap-20260905T180640Z-nY7AXQ.heap
```

This comparison was rerun offline while preparing the README using `/build/go/bin/pprof`.
It reported +60.90 MB cumulative sampled live space under `onRefreshDate`, with
`SlotImpl::set`, `SlotImpl::wrapCallback`, and `DispatcherImpl::post` on the allocation path.
Cumulative values overlap and must not be added. Sampling identifies allocation paths,
not exact queue contents.

GDB showed four registered worker dispatchers, no worker threads, and `workers_started_ = false`.
Between 18:34:12.138 and 18:35:24.380 UTC on 2026-09-05, each queue grew from 73,624 to
73,765 callbacks. A sampled queue-tail callback's vtable resolved to `SlotImpl::wrapCallback`.
The investigation record and original log contain the full observations. Not every callback
was inspected.

**Do not execute the GDB script unchanged.** It contains historical PID `2299982`, absolute
paths, and assumptions about 64-bit little-endian AArch64 libc++ internals. Verify the new
target, paths, symbols, and layout, and use a different log file. Attach pauses the process.
The investigation record explains the split-DWARF working-directory requirement.
No running Envoy process was started, restarted, or attached to while packaging this branch.

## Source chain

- [WorkerImpl registers its dispatcher](https://github.com/envoyproxy/envoy/blob/329dd5106e758b7b24a65af51b8a28e3a0568af5/source/server/worker_impl.cc#L50-L57).
- [Worker startup follows initialization](https://github.com/envoyproxy/envoy/blob/329dd5106e758b7b24a65af51b8a28e3a0568af5/source/server/server.cc#L1085-L1096).
- [Date refresh calls TLS set every 500ms](https://github.com/envoyproxy/envoy/blob/329dd5106e758b7b24a65af51b8a28e3a0568af5/source/common/http/date_provider_impl.cc#L25-L31).
- [TLS set posts to registered dispatchers](https://github.com/envoyproxy/envoy/blob/329dd5106e758b7b24a65af51b8a28e3a0568af5/source/common/thread_local/thread_local_impl.cc#L114-L124).

The investigation and README involved AI assistance; the submitter should review the materials
before sharing.
