defmodule Repatch.ExUnit do
  @moduledoc """
  Just `use Repatch.ExUnit` and you're ready for testing with `Repatch`.
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
