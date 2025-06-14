# Performance tips

`Repatch` was built with performance in mind and it tries to keep the runtime overhead as thin as possible.
Here is a list of all actions you may take in order to improve performance of your tests.

While some of these tips are very simple to adopt, others may require rewrites of your tests. But in any way,
treat these as **tips, not rules**, because `Repatch` must work correctly and efficiently without them.

## Use setup with recompile option

When `Repatch.patch/4` or `Repatch.fake/3` is called on the target module for the first time, this module will be
recompiled. Depending on the size of the module, it may take some time. Therefore it is recommended to recompile these modules
before starting the test suite (during the `Repatch.setup/1` call). It may not reduce overall test suite time, but it will
definitely help with having more consistent results when tracking slowest test cases.

## Disable unused modes

`Repatch` has optimizations to not lookup into the dispatch tables for modes which are disabled.
This advice also applies to async tests. If you use `global` test mode in async, feel free to
disable `shared` mode and then return `shared` and disable `global` during the `on_exit` callback.

## Prefer local to shared to global

In contrast to other tools, `Repatch` was designed with `async: true` in mind, that's why
shared and global modes perform more expensive lookups into shared memory, while local
one is the most efficient and simple.

## Disable history

When module is recompiled, history is enabled for every function in this module. And by default
**history tracks calls to any function in the module from all processes**. However, it is
possible to track calls to the patched function manually.

### For example

```elixir
history_agent = Agent.start_link(fn -> [] end)

Repatch.patch(MapSet, :new, fn list ->
  result = Repatch.super(MapSet.new(list))
  Agent.update(history_agent, fn h -> [{MapSet, :new, [list], result} | h] end)
end)

MapSet.new([1])
MapSet.new([1, 2])

history = Agent.get(history_agent, &Function.identity/1)

assert Enum.any?(history, &match?({MapSet, :new, [1 | _], %MapSet{}}, &1))
```

## Cleanup processes

If you're using processes which will outlive the test suite, and these processes call the patched modules, you should call `Repatch.cleanup/1` on them from time to time to clean history.

## Don't to patch kernel or recursive functions

That means if you have a function which returns result of `Enum.reduce` call, try not to patch it and
patch the private/public function which calls it. Otherwise, every call to this function will hit disptacher
and will be slowed down. **This tip is especially useful for recursive functions**.

It also applies to Erlang stdlib functions and modules and frequently called libraries like `:telemetry`

## Use `recompile_only` and `recompile_except` options

These options control the functions which are recompiled in the module. Functions, which are not
recompiled are not affected by patches and their history is no tracked, but on the other hand
they are not affected by additional runtime overhead like recompiled functions do.
