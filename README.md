# Repatch

<!-- MDOC -->

Repatch is a library for efficient, ergonomic and concise mocking/patching in tests (or not tests). It
provides an efficient and async-friendly replacement for Mox, ProtoMock, Patch, Mock and all other
similar libraries.

## Features

* **Patches any function or macro**. Elixir or Erlang, private or public (except BIF/NIF).

* **Async friendly**. With local, global, and allowances modes.

* **Boilerplate-free**. But you still can leverage classic explicit DI with Repatch.

* **Call history**.

* **Built-in async-friendly application env**. See `Repatch.Application`.

* **Mock behaviour and protocol implementation generation**. See `Repatch.Mock`

* **Supports expect-style mocking**. See `Repatch.Expectations`

* **Testing framework agnostic**. It even works in `iex` and remote shells.

## Installation

```elixir
def deps do
  [
    {:repatch, "~> 1.5"}
  ]
end
```

## One-minute intro

> for ExUnit users

1. Add `Repatch.setup()` into your `test_helper.exs` file after the `ExUnit.start()`

2. `use Repatch.ExUnit` in your test module

3. Call `Repatch.patch/3` to change implementation of any function in any module.

### For example

```elixir
defmodule ThatsATest do
  use ExUnit.Case, async: true
  use Repatch.ExUnit

  test "that's not a MapSet.new" do
    Repatch.patch(MapSet, :new, fn _list ->
      %{thats_not: :a_map_set}
    end)

    assert MapSet.new([1, 2, 3]) == %{thats_not: :a_map_set}

    assert Repatch.called?(MapSet, :new, 1)
  end
end
```

<!-- MDOC -->

## Further reading

Please check out the [docs](https://hexdocs.pm/repatch) for all available features.

## Special thanks

To [`ihumanable`](https://github.com/ihumanable) for [`Patch`](https://hexdocs.pm/patch) library which was an inspiration and a good example for `Repatch`.
