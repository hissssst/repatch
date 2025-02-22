# Isolation modes

`Repatch` has 3 different isolation modes for patch isolation
when testing with `async: true`, and it is important to know when and how to use each one of them.

## Local mode

This mode is always enabled and isolates applied patches only to the **current process**.
Any other process will be unable to execute the patch that this process set.
However, local patches do not affect other processes and it is __completely safe__ to use this mode with
`async: true` testing option. This mode is also the fastest one in terms of runtime overhead.

## Shared mode

This mode is enabled by default but it can be disabled with `enable_shared: false` option in the `Patch.setup/1` call.
It isolates the patch for the **current process, Task processes it creates and any allowed process**. This mechanic is similar to testing
with allowances in `Ecto` and `Mox`, though it is slightly different. Use `Repatch.allow/2` to share the patch with other processes.

Consider this example

```elixir
pid = Server.start()

# Everything works as expected without patch
assert %MapSet{} = Server.call(pid, MapSet, :new, [])
assert %MapSet{} = MapSet.new()

# Now we apply patch and prove that only current process sees it
Repatch.patch(MapSet, :new, [mode: :shared], fn -> :hello end)
assert %MapSet{} = Server.call(pid, MapSet, :new, [])
assert :hello = MapSet.new()

# And now we allow the server to have access to this patch and we see
# that it resolves to the same patch as the current process
Repatch.allow(self(), pid)
assert :hello = Server.call(pid, MapSet, :new, [])
assert :hello = MapSet.new()
```

Due to it's nature, it is also safe to use this mode with `async: true` testing option. However, if two
tests running at the same time, will try to allow the same third process to call shared patches,
one of the `allow` calls will fail, so it's up to developer to make sure that processes are not shared
between tests.

It also has integration with `Task` module similar to `Mox`'s one, and it allows spawned tasks to
call the patches of their original caller automatically (without explicit `Repatch.allow/3` call).

## Global mode

This mode is disabled by default and must be enabled with `enable_global: true` option in `Patch.setup` call.
It doesn't isolate the patch in any way, what means that the patch will be accessible by the **current process and any other process**.
This mechanic is similar to testing with `Patch` library or global mode in `Mox`.
