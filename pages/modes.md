# Isolation modes

`Repatch` has 3 different isolation modes for patch isolation
when testing with `async: true`, and it is important to know when and how to use each one of them.

## Local mode

This mode is always enabled and work by applying patches only to the **current process**.
That means that any other process will be unable to execute the patch that the other process set.
However, local patches do not affect other processes and it is __completely safe__ to use this mode with
`async: true` testing option. This mode is also the fastest one in terms of runtime overhead.

## Shared mode

This mode is enabled by default but it can be disabled with `enable_shared: false` setting in the `Patch.setup/1` call.
It works by storing the patch for the **current process and any allowed process**. This mechanic is similar to testing
with allowances in `Ecto` and `Mox`, though it is slitghtly different. To allow other process to use shared
patches of the current process or any other process, one should use `Repatch.allow/2`

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

## Global mode

This mode is disabled by default and must be enabled with `enable_global: true` setting in `Patch.setup` call.
It works by storing the patch for the **current process and any other process**. This mechanic is similar to testing
with `Patch` library or global mode in `Mox`. Other processes will be able to call the patch without any explicit
allowance or anything. Therefore, this mode can be used with `async: true` only when it is guaranteed that
it is okay if other processes may call the patched function or it is guaranteed that other processes
will never call the patched function.
