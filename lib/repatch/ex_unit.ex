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

  * `assert_expectations` (`t:boolean/0`) — Whether to perform assertion
  on expectations during `on_exit` or not. See `Repatch.Expectations.expect/4`. Defaults to `false`.
  """

  defmacro __using__(opts) do
    owner = Macro.var(:owner, __MODULE__)
    expectations_state = Macro.var(:expectations_state, __MODULE__)

    isolate_env =
      if mode = opts[:isolate_env] do
        quote do
          Repatch.Application.patch_application_env(mode: unquote(mode))
          on_exit(fn -> Repatch.Application.cleanup(unquote(owner)) end)
        end
      end

    assert_expectations_setup =
      if opts[:assert_expectations] do
        quote do
          unquote(expectations_state) = Repatch.Expectations.Queues.init()
        end
      end

    assert_expectations_exit =
      if opts[:assert_expectations] do
        quote do
          states = Repatch.Expectations.Queues.all(unquote(expectations_state))

          unless Repatch.Expectations.expectations_empty?(states) do
            message =
              for(
                {{module, function, arity}, expectations} <-
                  Repatch.Expectations.pending_expectations(states),
                into: "Some expectations were not satisfied\n\n"
              ) do
                {tag, times} =
                  for(
                    {tag, times, _} <- expectations,
                    tag != :at_least and times != 0,
                    reduce: {:exactly, 0}
                  ) do
                    {acctag, acctimes} -> {min(tag, acctag), times + acctimes}
                  end

                "  #{inspect(module)}.#{function}/#{arity} expected to be called #{tag} #{times} more times\n"
              end

            flunk(message)
          end
        end
      end

    quote do
      require Repatch

      setup do
        unquote(owner) = self()
        unquote(isolate_env)
        unquote(assert_expectations_setup)

        on_exit(fn ->
          unquote(assert_expectations_exit)
          Repatch.Expectations.cleanup()
          Repatch.cleanup(unquote(owner))
        end)
      end
    end
  end
end
