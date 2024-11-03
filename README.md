# Repatch

<!-- MDOC -->

Repatch is a library for efficient, ergonomic and concise mocking/patching in tests (or not tests)

## Features

1. Patch **any** function or macro (except NIF and BIF). Elixir or Erlang, private or public, it can be patched!

2. Designed to work with `async: true`. Has 3 isolation levels for testing multi-processes scenarios.

3. Requires **no boilerplate or explicit DI**. Though, you are completely free to write in this style with Repatch!

4. Every patch is consistent and **applies to direct or indirect calls** and **any process** you choose.

5. Powerful **call history** tracking.

6. `super` and `real` helpers for calling original functions.

7. **Works with other testing frameworks** and even in environments like `iex` or remote shell.

8. Get **async-friendly application env!** with just a single line in test. See `Repatch.Application`.

## Installation

```elixir
def deps do
  [
    {:repatch, "~> 1.0"}
  ]
end
```

## One-minute intro

> for ExUnit users

1. Add `Repatch.setup()` into your `test_helper.exs` file after the `ExUnit.start()`

2. `use Repatch.ExUnit` in your test module

3. Call `Repatch.patch` or `Repatch.fake` to change implementation of any function and any module.

### For example

```elixir
defmodule ThatsATest do
  use ExUnit.Case, async: true
  use Repatch.ExUnit

  test "that's not a MapSet.new" do
    Repatch.patch(MapSet, :new, fn ->
      %{thats_not: :a_map_set}
    end)

    assert MapSet.new() == %{thats_not: :a_map_set}

    assert Repatch.called?(MapSet, :new, 1)
  end
end
```

<!-- MDOC -->

## Further reading

Please check out the [docs](https://hexdocs.pm/repatch) for all available features.

## Special thanks

To [`ihumanable`](https://github.com/ihumanable) for [`Patch`](https://hexdocs.pm/patch) library which was an inspiration and a good example for `Repatch`.
