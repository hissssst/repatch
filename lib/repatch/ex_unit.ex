defmodule Repatch.ExUnit do
  @moduledoc """
  An `ExUnit`-friendly helper to be used in testing. Just add

  ```elixir
  use Repatch.ExUnit
  ```

  Somewhere after the `use ExUnit.Case` line and this helper will setup
  cleaning of `Repatch` state and application env isolation if it is enabled.

  ## Options

  * `isolate_env` (`false` | `:local` | `:shared` | `:global`) — Whether to enable
  application env isolation and what mode to use for it. See `t:Repatch.mode/0` or
  `Repatch.Application.patch_application_env/1` for more info. Defaults to `false`.
  """

  defmacro __using__(opts \\ []) do
    owner = Macro.var(:owner, __MODULE__)

    isolate_env =
      if mode = opts[:isolate_env] do
        quote do
          Repatch.Application.patch_application_env(mode: unquote(mode))
          on_exit(fn -> Repatch.Application.cleanup(unquote(owner)) end)
        end
      end

    quote do
      require Repatch

      setup do
        unquote(owner) = self()
        unquote(isolate_env)
        on_exit(fn -> Repatch.cleanup(unquote(owner)) end)
      end
    end
  end
end
