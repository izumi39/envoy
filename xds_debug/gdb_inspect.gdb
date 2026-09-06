set pagination off
set confirm off
set may-call-functions off
set print pretty on
set print elements 4
set print max-depth 4
set debuginfod enabled off
set auto-load off
set logging file /workspaces/envoy/xds_debug/gdb_initial_20260906.log
set logging overwrite off
set logging enabled on
file /workspaces/envoy/bazel-bin/source/exe/envoy-static
attach 2299982
info threads
python
import gdb, datetime, struct
print("INSPECTION UTC", datetime.datetime.now(datetime.timezone.utc).isoformat())
try:
    found = False
    for thread in gdb.selected_inferior().threads():
        thread.switch()
        frame = gdb.newest_frame()
        while frame:
            if frame.name() == 'Envoy::StrippedMainBase::runServer':
                frame.select()
                gdb.execute('set $main = this')
                gdb.execute('set $srv = (Envoy::Server::InstanceBase *)$main->server_.__ptr_')
                gdb.execute('set $tls = $main->tls_.__ptr_')
                gdb.execute('p $srv->workers_started_')
                registered = gdb.parse_and_eval('$tls->registered_threads_')
                count = int(registered['__size_'])
                print('REGISTERED_WORKERS', count)
                ref_type = registered.type.strip_typedefs().template_argument(0)
                node = registered['__end_']['__next_']
                for i in range(min(count, 16)):
                    # libc++ list node: base links followed by the reference_wrapper value.
                    base_size = 16
                    assert ref_type.sizeof == 8
                    ref = gdb.Value(int(node) + base_size).cast(ref_type.pointer()).dereference()
                    dispatcher = ref['__f_'].cast(gdb.lookup_type('Envoy::Event::DispatcherImpl').pointer())
                    print('WORKER', i, 'DISPATCHER', dispatcher)
                    gdb.set_convenience_variable('disp', dispatcher)
                    queue = dispatcher.dereference()['post_callbacks_']
                    print('QUEUE_SIZE', int(queue['__size_']))
                    callback_type = queue.type.strip_typedefs().template_argument(0)
                    tail = int(queue['__end_']['__prev_'])
                    callback = gdb.Value(tail + 16).cast(callback_type.pointer()).dereference()
                    gdb.set_convenience_variable('queued_cb', callback)
                    gdb.execute('set print max-depth 8')
                    gdb.execute('p /r $queued_cb')
                    if i == 0:
                        gdb.execute('set print object on')
                        gdb.execute('set $queued_fn = (std::__1::function<void()> *)$queued_cb.state_.remote.target')
                        gdb.execute('p /r *$queued_fn')
                        gdb.execute('info symbol *(void **)$queued_fn->__f_.__f_')
                        gdb.execute('p /r *$queued_fn->__f_.__f_')
                    node = struct.unpack('<Q', bytes(gdb.selected_inferior().read_memory(int(node) + 8, 8)))[0]
                found = True
                break
            frame = frame.older()
        if found:
            break
    if not found:
        print('InstanceBase::run frame not found')
finally:
    gdb.execute('detach')
    print('DETACHED UTC', datetime.datetime.now(datetime.timezone.utc).isoformat())
end
quit
