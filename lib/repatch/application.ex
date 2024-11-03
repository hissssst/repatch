defmodule Repatch.Application do
  @moduledoc """
  Helper module for patching application env.

  ## Usage

  1. In your `test_helper.exs` add this line
  ```elixir
  Repatch.Application.setup()
  ```

  2. Add this to your test file
  ```elixir
  use Repatch.ExUnit, isolate_env: :local # or :shared or :global
  ```

      Or if just call `Repatch.Application.patch_application_env/1` and `Repatch.Application.cleanup/1` manually in setup or tests.

  3. Done! Now you can just call regular `Application` functions and they will
  affect only local (or shared) application env, so changes are not affecting other processes

  ## How it works

  It just patches `:application` module functions which work with application env and replaces
  their implementation with a thing which calls repatch-driven application env.

  ## Drawbacks

  It may not work for code which calls to internal and unspecified Erlang application env
  implementation like `ac_tab` ets table or `application_controller` directly.
  It also ignores `persistent` and `timeout` options.
  """

  @typedoc """
  See `t:Repatch.patch_option/0` for more information.
  """
  @type patch_application_env_option() :: Repatch.patch_option()

  @doc """
  Sets up the state for patching application env

  ## Example

  in your `test/test_helper.exs` file:
  ```elixir
  ExUnit.start()
  Repatch.setup()
  Repatch.Application.setup()
  ```
  """
  @spec setup() :: :ok
  def setup do
    Repatch.setup_table(:repatch_application_env, [:set, :named_table, :public])
    Repatch.recompile(:application)
    :persistent_term.put(:repatch_application_env_enabled, true)
    :ok
  end

  @doc """
  Patches functions related to application env so that env is isolated.
  Accepts a list of options like the regular process.

  ## Example

      iex> Application.get_env(:ex_unit, :any)
      nil
      iex> Repatch.Application.patch_application_env(force: true)
      iex> Application.put_env(:ex_unit, :any, :thing)
      iex> Application.get_env(:ex_unit, :any)
      :thing
      iex> Task.await(Task.async(fn -> Application.get_env(:ex_unit, :any) end))
      nil
  """
  @spec patch_application_env([patch_application_env_option()]) :: :ok
  def patch_application_env(opts \\ []) do
    unless :persistent_term.get(:repatch_application_env_enabled, false) do
      raise ArgumentError,
            "Application env patching is not initialized. Please call Repatch.Application.setup first"
    end

    mode = Keyword.get(opts, :mode, :local)

    Repatch.patch(:application, :set_env, opts, fn config ->
      owner = owner(mode)

      for {app, env} <- config, {key, value} <- env do
        :ets.insert(:repatch_application_env, {{owner, app, key}, true, value})
      end
    end)

    Repatch.patch(:application, :set_env, opts, fn config, _opts ->
      :application.set_env(config)
    end)

    Repatch.patch(:application, :set_env, opts, fn app, key, value ->
      :ets.insert(:repatch_application_env, {{owner(mode), app, key}, true, value})
    end)

    Repatch.patch(:application, :set_env, opts, fn app, key, value, _opts ->
      :application.set_env(app, key, value)
    end)

    Repatch.patch(:application, :unset_env, opts, fn app, key ->
      :ets.insert(:repatch_application_env, {{owner(mode), app, key}, false, nil})
    end)

    Repatch.patch(:application, :unset_env, opts, fn app, key, _opts ->
      :application.unset_env(app, key)
    end)

    Repatch.patch(:application, :get_env, opts, fn key ->
      case :application.get_application() do
        :undefined -> :undefined
        {:ok, app} -> :application.get_env(app, key)
      end
    end)

    Repatch.patch(:application, :get_env, opts, fn app, key ->
      case :ets.lookup(:repatch_application_env, {owner(mode), app, key}) do
        [{_, false, _}] -> :undefined
        [{_, true, value}] -> {:ok, value}
        [] -> Repatch.super(:application, :get_env, [app, key])
      end
    end)

    Repatch.patch(:application, :get_env, opts, fn app, key, default ->
      case :ets.lookup(:repatch_application_env, {owner(mode), app, key}) do
        [{_, false, _}] -> default
        [{_, true, value}] -> value
        [] -> Repatch.super(:application, :get_env, [app, key, default])
      end
    end)

    Repatch.patch(:application, :get_all_env, opts, fn ->
      case :application.get_application() do
        :undefined -> []
        {:ok, app} -> :application.get_all_env(app)
      end
    end)

    Repatch.patch(:application, :get_all_env, opts, fn app ->
      {removed, overrides} =
        :repatch_application_env
        |> :ets.select([{{{owner(mode), app, :"$2"}, :"$1", :"$3"}, [], [[:"$1", :"$2", :"$3"]]}])
        |> Enum.reduce({[], []}, fn
          [true, key, value], {removed, overrides} -> {removed, [{key, value} | overrides]}
          [false, key, _], {removed, overrides} -> {[key | removed], overrides}
        end)

      old_env =
        :application
        |> Repatch.super(:get_all_env, [app])
        |> Keyword.drop(removed)

      Enum.uniq(overrides ++ old_env)
    end)

    :ok
  end

  @doc """
  Cleans up a temporary env set up by the process. Use it after the test ends
  or if you want to reset application env back to what it used to be
  before the patch_application_env call.

  ## Example

      iex> Application.get_env(:ex_unit, :any)
      nil
      iex> Repatch.Application.patch_application_env(force: true)
      iex> Application.put_env(:ex_unit, :any, :thing)
      iex> Application.get_env(:ex_unit, :any)
      :thing
      iex> Repatch.Application.cleanup()
      iex> Application.get_env(:ex_unit, :any)
      nil
  """
  @spec cleanup(pid()) :: :ok
  def cleanup(pid \\ self()) do
    owner = Repatch.owner(pid) || pid
    :ets.match_delete(:repatch_application_env, {{owner, :_, :_}, :_, :_})
    :ok
  end

  defp owner(:local) do
    self()
  end

  defp owner(:shared) do
    Repatch.owner(self()) || self()
  end

  defp owner(:global) do
    :global
  end
end
