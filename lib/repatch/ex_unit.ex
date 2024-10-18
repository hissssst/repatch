defmodule Repatch.ExUnit do
  @moduledoc """
  An `ExUnit`-friendly helper to be used in testing. Just add

  ```elixir
  use Repatch.ExUnit
  ```

  Somewhere after the `use ExUnit.Case` line and this helper will setup
  cleaning of `Repatch` state
  """

  defmacro __using__(_opts \\ []) do
    quote do
      require Repatch

      setup do
        pid = self()
        on_exit(fn -> Repatch.cleanup(pid) end)
      end
    end
  end
end
