# Repatch

<!-- MDOC -->

Repatch is a library for efficient, ergonomic and concise mocking/patching in tests (or not tests)

## Features

1. Patch **any** function or macro (except NIF and BIF). You can even patch and call private functions in test, or Erlang modules

2. Designed to work with `async: true`. Has 3 isolation levels for testing multi-processes scenarios.

3. Does not require any explicit boilerplate or DI. Though, you are completely free to use it with Repatch!

5. Powerful call history tracking.

6. `super` and `real` to help you call real implementations of the module.

7. Works with other test frameworks and even in non-testing environments like `iex` or remote shell.

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
