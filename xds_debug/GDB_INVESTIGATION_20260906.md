# Memory growth during xDS initialization: GDB investigation

## Scope and objectives

- The user authorized the GDB investigation and requested a record of the process.
- Inspection was limited to reading process fields, threads, and callbacks. No inferior functions
  were called, no breakpoints were set, and no process memory was written. Envoy was neither
  restarted nor terminated.
- GDB attach briefly pauses the process; each inspection was followed by detach. This was not
  non-intrusive sampling. Do not treat this interval as a baseline unaffected by debugging.
- Container: `6b93e3ac91fb`; target PID: `2299982`.
- Command line: `./bazel-bin/source/exe/envoy-static -c xds_debugging.yaml --concurrency 4 --disable-hot-restart --log-level info`.
- All raw GDB output was appended to `gdb_initial_20260906.log`. The final inspection commands
  are in `gdb_inspect.gdb`.
- The log uses UTC; Beijing time is UTC + 8 hours.

## Preparation and commands executed

GDB was initially absent from the container. GDB 16.3 and its dependencies were installed as
root: 13 new packages, with no package upgrades. Envoy was not restarted.

```bash
docker exec -u root 6b93e3ac91fb apt-get install -y --no-install-recommends --no-upgrade gdb
docker exec -w /build/bazel_root/base/execroot/_main 6b93e3ac91fb \
  gdb -nx -q -batch -x /workspaces/envoy/xds_debug/gdb_inspect.gdb
```

The inspection script disabled auto-loading and debuginfod and set `set may-call-functions off`.
GDB Python ran only inside the debugger, reading process state through DWARF fields and
`read_memory`. Variables such as `$main` are GDB convenience variables, not Envoy fields.

## Problems encountered and how they were resolved

1. The first attempt to load the binary from the default directory failed before attach because
   the split-DWARF file `main.dwo` could not be found. A check of `/proc/2299982/status` showed
   `TracerPid: 0`.
2. The DWO files did exist. Symbol loading succeeded after changing the working directory to
   `/build/bazel_root/base/execroot/_main`.
3. In the optimized build, `this` in `InstanceBase::run()` was optimized out. Instead,
   `server_.__ptr_` and `tls_.__ptr_` were read through `this` in the caller frame,
   `StrippedMainBase::runServer()`.
4. A complete `__list_node<...>` type was not directly available for lookup, and the DWARF size
   of the node pointer's target type could not establish the actual node layout. The current
   toolchain's libc++ `list` and `reference_wrapper.h` were inspected to verify that the value
   follows two 8-byte list pointers and that `reference_wrapper` stores its reference in `__f_`.
5. Using that verified layout, the four nodes of the registered-thread list were read. The
   dispatcher's actual DWARF type was then used to read `post_callbacks_.__size_`. Neither
   `size()` nor any other C++ function was called.
6. Investigating the layout required several brief attachments rather than the two originally
   planned. Every successful attachment was followed by detach. Errors were retained in the
   original log.

## First complete queue observation

UTC `2026-09-05T18:34:12.137928` (September 6, 02:34:12 Beijing time):

- `workers_started_ = false`.
- `registered_threads_` contained 4 entries.
- The process had 6 threads: the main thread, AccessLogFlush, two watchdogs, GrpcGoogClient,
  and grpc_global_tim. There were no `wrk:worker_*` threads.

| Registration order | Dispatcher address | post_callbacks_ length |
|---|---|---:|
| 0 | `0x10ebffa72dc0` | 73624 |
| 1 | `0x10ebffa73080` | 73624 |
| 2 | `0x10ebffa73340` | 73624 |
| 3 | `0x10ebffa73600` | 73624 |

These indices reflect registration order; dispatcher names were not read to verify their mapping.

## Subsequent observations

All four dispatchers had identical queue lengths at each observation:

| Beijing time (2026-09-06) | Queue length per dispatcher | Change from previous row |
|---|---:|---:|
| 02:34:12.138 | 73624 | — |
| 02:35:24.380 | 73765 | +141 |
| 02:35:46.341 | 73806 | +41 |
| 02:39:38.904 | 74266 | +460 |

The first two observations were 72.242 seconds apart. Each queue gained 141 entries, approximately
1.95 entries per second. This interval included brief debugger pauses and therefore does not
represent exactly 72.242 seconds of process execution. The result is consistent with one post
every 500ms, but the source of every newly queued callback was not individually identified.

At every observation, `workers_started_` was false and the thread list contained no worker threads.

## Callback ownership

During the second observation, the `AnyInvocable` at the tail of each of the four queues was read
directly. Their manager/invoker pointers referred to the remote-storage handling functions for
`std::__1::function<void()>`. During the final observation, the std::function at the tail of the
first dispatcher's queue was inspected further. Looking up its vtable address returned:

```text
vtable for std::__1::__function::__func<
  Envoy::ThreadLocal::InstanceImpl::SlotImpl::wrapCallback(
    std::__1::function<void ()> const&)::$_0,
  void ()> + 16
```

This directly establishes that the queue retains a callback object produced by wrapCallback.
Incomplete RTTI prevented GDB from automatically expanding the specific lambda capture fields.
No attempt was made to force an interpretation of its captured Date string, and the callback
was not invoked.

`AnyInvocable::state_.remote.size` was not used to determine memory size on this nontrivial
remote-manager path. The raw printed value was not used to infer allocation size or memory
corruption.

## Conclusions and limitations

- Directly verified: four worker dispatchers were registered, the worker threads had not started,
  and all four pending callback queues continued growing together.
- Directly verified: the inspected queue-tail object retained a wrapCallback lambda through
  AnyInvocable → std::function.
- Together with the earlier heap diff showing growth under onRefreshDate → SlotImpl::set and
  the source code posting to registered workers every 500ms, the evidence strongly supports
  Date refresh callbacks accumulating in inactive worker dispatchers as the memory-growth mechanism.
- The investigation did not establish that every callback in every queue was a Date update.
  It did not change xDS availability, start the workers to verify queue drainage, implement
  a fix, or run regression tests.
- This investigation installed GDB and created the record and inspection script. It did not
  modify Envoy source code, configuration, process fields, or its invocation.

## Final process state

Final GDB detach: UTC `2026-09-05T18:39:40.695458`.

At UTC `2026-09-05T18:42:44`, read-only checks through `/proc` and `ps` confirmed:

```text
State: S (sleeping)
TracerPid: 0
Threads: 6
PID: 2299982
STARTED: Sat Sep 5 08:17:00 2026
```

The process retained its original PID, had not been restarted, and had no debugger left attached.

## Original log index

- `gdb_initial_20260906.log:273`: first complete queue inspection.
- `gdb_initial_20260906.log:348`: second queue counts and the objects retained by AnyInvocable.
- `gdb_initial_20260906.log:519`: final queue counts.
- `gdb_initial_20260906.log:548`: wrapCallback vtable symbol.
- `gdb_initial_20260906.log:600`: final detach timestamp.

Warning: `gdb_inspect.gdb` hard-codes the PID, file paths, and AArch64 libc++ layout from this
investigation. It is a historical command record, not a general-purpose script. Revalidate the
target and assumptions before running it again.
