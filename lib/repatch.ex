defmodule Repatch do
  @external_resource Path.join([__DIR__, "../README.md"])

  @moduledoc """
  #{@external_resource |> File.read!() |> String.split("<!-- MDOC -->") |> tl() |> hd()}
  """

  alias Repatch.Recompiler

  @forbidden_modules [
    Keyword,
    Repatch,
    Repatch.Recompiler,
    Repatch.ExUnit,
    Enum,
    :erlang,
    :code,
    :ets,
    :persistent_term
  ]

  if false do
    defmacrop debug(message) do
      quote do
        IO.puts("#{inspect(self())} | #{unquote(message)}")
      end
    end
  else
    defmacrop debug(_), do: nil
  end

  @typedoc """
  Options passed in the `setup/1` function.

  * `enable_global` (boolean) — Whether to allow global mocks in test suites. Defaults to `false`.
  * `enable_shared` (boolean) — Whether to allow shared mocks in test suites. Defaults to `true`.
  * `enable_history` (boolean) — Whether to enable calls history tracking. Defaults to `true`.
  * `recompile` (list of modules) — What modules should be recompiled before test starts. Modules are recompiled lazily by default. Defaults to `[]`.
  * `ignore_forbidden_module` (boolean) — Whether to ignore the warning about forbidden module being recompiled. Works only when `recompile` is specified. Defaults to `false`.
  """
  @type setup_option ::
          recompile_option()
          | {:enable_global, boolean()}
          | {:enable_shared, boolean()}
          | {:enable_history, boolean()}
          | {:recompile, module() | [module()]}

  @typedoc """
  Mode of the patch or fake
  """
  @type mode :: :local | :shared | :global

  @type tag :: :patched | mode()

  @type recompile_option :: {:ignore_forbidden_module, boolean()}

  @doc """
  Setup function. Use it only once per test suite.
  See `t:setup_option/0` for available options.

  It is suggested to be put in the `test_helper.exs` after the `ExUnit.start()` line
  """
  @spec setup([setup_option()]) :: :ok
  def setup(opts \\ []) do
    global_hooks_enabled = Keyword.get(opts, :enable_global)
    shared_hooks_enabled = Keyword.get(opts, :enable_shared)
    history_enabled = Keyword.get(opts, :enable_history)

    setup_table(:repatch_module_states, [:set, :named_table, :public])
    setup_table(:repatch_state, [:set, :named_table, :public])

    case global_hooks_enabled do
      nil ->
        :ok

      true ->
        setup_table(:repatch_global_hooks, [:set, :named_table, :public])
        :persistent_term.put(:repatch_global_hooks_enabled, true)

      false ->
        :persistent_term.put(:repatch_global_hooks_enabled, false)
    end

    case shared_hooks_enabled do
      nil ->
        setup_table(:repatch_shared_hooks, [:set, :named_table, :public])
        setup_table(:repatch_shared_allowances, [:set, :named_table, :public])

      true ->
        setup_table(:repatch_shared_hooks, [:set, :named_table, :public])
        setup_table(:repatch_shared_allowances, [:set, :named_table, :public])
        :persistent_term.put(:repatch_shared_hooks_enabled, true)

      false ->
        :persistent_term.put(:repatch_shared_hooks_enabled, false)
    end

    case history_enabled do
      nil ->
        setup_table(:repatch_history, [:duplicate_bag, :named_table, :public])

      true ->
        setup_table(:repatch_history, [:duplicate_bag, :named_table, :public])
        :persistent_term.put(:repatch_history_enabled, true)

      false ->
        :persistent_term.put(:repatch_history_enabled, false)
    end

    for module <- List.wrap(Keyword.get(opts, :recompile, [])) do
      recompile(module, opts)
    end

    debug("setup successful")

    :ok
  end

  defp setup_table(name, options) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, options)
      _ -> :ok
    end
  end

  defp recompile(module, opts) do
    if module in @forbidden_modules and not Keyword.get(opts, :ignore_forbidden_module, false) do
      raise ArgumentError,
            "Module #{inspect(module)} is a forbidden to patch module, because it may interfere with the Repatch logic"
    end

    debug("Recompiling #{inspect(module)}")

    case :ets.lookup(:repatch_module_states, module) do
      [{_, :recompiling}] ->
        debug("#{inspect(module)} awaiting recompilation")
        await_recompilation(module)

      [{_, {:recompiled, _}}] ->
        debug("#{inspect(module)} found recompiled")
        :ok

      [] ->
        if :ets.insert_new(:repatch_module_states, {module, :recompiling}) do
          {:ok, bin} = Recompiler.recompile(module)
          :ets.insert(:repatch_module_states, {module, {:recompiled, bin}})
          debug("Recompiled #{inspect(module)}")
        else
          await_recompilation(module)
        end
    end
  end

  @doc """
  Cleans up current test process (or any other process) Repatch-state.
  It is recommended to be called during the test exit.
  Check out `Repatch.ExUnit` module which set up this callback up.
  """
  @spec cleanup(pid()) :: :ok
  def cleanup(pid \\ self()) do
    if pid == self() do
      Enum.each(:erlang.get_keys(), fn
        {:repatch_hooks, _, _, _} = key -> :erlang.erase(key)
        _ -> :ok
      end)

      debug("cleanup local")
    end

    if :persistent_term.get(:repatch_shared_hooks_enabled, true) do
      :ets.match_delete(:repatch_shared_hooks, {{:_, :_, :_, pid}, :_})
      :ets.match_delete(:repatch_shared_allowances, {:_, pid})
      :ets.match_delete(:repatch_shared_allowances, {pid, :_})
    end

    if :persistent_term.get(:repatch_global_hooks_enabled, false) do
      :ets.match_delete(:repatch_global_hooks, {{:_, :_, :_}, pid, :_})
    end

    cleanup_history(pid)

    debug("cleanup done")

    :ok
  end

  defp cleanup_history(pid) do
    if :persistent_term.get(:repatch_history_enabled, true) do
      :ets.match_delete(:repatch_history, {{:_, :_, :_, pid}, :_, :_})
    end
  end

  @doc """
  Clears all state of the `Repatch` including all patches, fakes and history, and reloads all
  old modules back, disabling history collection on them. It is not recommended to be called
  during testing and it is suggested to be used only when Repatch is used in iex session.
  """
  @spec restore_all() :: :ok
  def restore_all do
    :repatch_module_states
    |> :ets.tab2list()
    |> Enum.each(fn {module, state} ->
      case state do
        {:recompiled, original_binary} ->
          Recompiler.load_binary(module, original_binary)

        :recompiling ->
          await_recompilation(module)

        _ ->
          :ok
      end
    end)

    :ets.delete_all_objects(:repatch_module_states)
    :ets.delete_all_objects(:repatch_state)
    :ets.delete_all_objects(:repatch_history)
    :ets.delete_all_objects(:repatch_global_hooks)
    :ets.delete_all_objects(:repatch_shared_hooks)
    :ets.delete_all_objects(:repatch_shared_allowances)

    :ok
  end

  @typedoc """
  Options passed in the `spy/2` function.

  * `by` (pid) — What process history to clean. Defaults to `self()`.
  * `ignore_forbidden_module` (boolean) — Whether to ignore the warning about forbidden module is being spied. Defaults to `false`.
  """
  @type spy_option :: recompile_option() | {:by, pid()}

  @doc """
  Cleans the existing history of current process calls to this module
  and starts tracking new history of all calls to the specified module.

  Be aware that it recompiles the module if it was not patched or spied on before, which may take some time.
  """
  @spec spy(module(), [spy_option()]) :: :ok
  def spy(module, opts \\ []) do
    pid = Keyword.get(opts, :by, self())
    recompile(module, opts)
    cleanup_history(pid)
    :ok
  end

  @typedoc """
  Options passed in the `fake/3` function.

  * `ignore_forbidden_module` (boolean) — Whether to ignore the warning about forbidden module is being spied. Defaults to `false`.
  * `force` (boolean) — Whether to override existing patches and fakes. Defaults to `false`.
  * `mode` (`:local` | `:shared` | `:global`) — What mode to use for the fake. See `t:mode/0` for more info. Defaults to `:local`.
  """
  @type fake_option :: patch_option()

  @doc """
  Replaces functions implementation of the `real_module` with functions
  of the `fake_module`.

  See `t:fake_option/0` for available options.
  """
  @spec fake(module(), module(), [fake_option()]) :: :ok
  def fake(real_module, fake_module, opts \\ [])

  def fake(m, m, _opts) do
    raise ArgumentError, "Can't fake module with itself #{inspect(m)}"
  end

  def fake(real_module, fake_module, opts) do
    exports = real_module.module_info(:exports)
    recompile(real_module, opts)

    for {function, arity} <- exports do
      hook = fn args -> {:ok, apply(fake_module, function, args)} end
      add_hook(real_module, function, arity, hook, opts)
    end

    :ok
  end

  # It's a macro because we don't want to add an extra entry in stacktrace when raising
  defmacrop raise_wrong_dotcall(ast) do
    quote do
      raise CompileError,
        description:
          "Expected call like Module.function(1, 2, 3). Got #{Code.format_string!(Macro.to_string(unquote(ast)))}",
        line: __CALLER__.line,
        file: __CALLER__.file
    end
  end

  defp maybe_raise_repatch_generated(function, caller, name) do
    function_name = Atom.to_string(function)

    if String.starts_with?(function_name, "__") and String.ends_with?(function_name, "_repatch") do
      raise CompileError,
        description: "Can't call #{name}/1 on Repatch-generated functions",
        line: caller.line,
        file: caller.file
    end
  end

  @doc """
  Use this on a call which would result only to unpatched versions of functions to be called on the whole stack of calls.
  Works only on calls in `Module.function(arg0, arg1, arg2)` format.
  """
  defmacro real({{:., _dotmeta, [_module, function]}, _meta, _args} = call) do
    maybe_raise_repatch_generated(function, __CALLER__, :real)

    quote do
      :erlang.put(:repatch_bypass_hooks, true)

      try do
        unquote(call)
      after
        :erlang.erase(:repatch_bypass_hooks)
      end
    end
  end

  defmacro real(other) do
    raise_wrong_dotcall(other)
  end

  @doc """
  Use this on a call which would result only on one unpatched version of the function to be called.
  Works only on calls in `Module.function(arg0, arg1, arg2)` format.
  """
  defmacro super({{:., _, [module, function]}, meta, args}) when is_atom(function) do
    super_function = Recompiler.super_name(function)

    maybe_raise_repatch_generated(function, __CALLER__, :super)

    {:apply, meta, [module, super_function, args]}
  end

  defmacro super(other) do
    raise_wrong_dotcall(other)
  end

  @doc """
  Just a compiler-friendly wrapper to call private functions on the module.
  Works only on calls in `Module.function(arg0, arg1, arg2)` format.
  """
  defmacro private({{:., _, [module, function]}, meta, args}) when is_atom(function) do
    private_function = Recompiler.private_name(function)

    maybe_raise_repatch_generated(function, __CALLER__, :private)

    {:apply, meta, [module, private_function, args]}
  end

  defmacro private(other) do
    raise_wrong_dotcall(other)
  end

  @typedoc """
  Options passed in the `patch/4` function.

  * `ignore_forbidden_module` (boolean) — Whether to ignore the warning about forbidden module is being spied. Defaults to `false`.
  * `force` (boolean) — Whether to override existing patches and fakes. Defaults to `false`.
  * `mode` (`:local` | `:shared` | `:global`) — What mode to use for the patch. See `t:mode/0` for more info. Defaults to `:local`.
  """
  @type patch_option ::
          recompile_option()
          | {:mode, :local | :shared | :global}
          | {:force, boolean()}

  @doc """
  Substitutes implementation of the function with a new one.
  Starts tracking history on all calls in the module too.
  See `t:patch_option/0` for available options.

  Be aware that it recompiles the module if it was not patched or spied on before, which may take some time.
  """
  @spec patch(module(), atom(), [patch_option()], function()) :: :ok
  def patch(module, function, opts \\ [], func) do
    recompile(module, opts)

    arity =
      func
      |> :erlang.fun_info()
      |> Keyword.fetch!(:arity)

    unless {Recompiler.super_name(function), arity} in module.module_info(:exports) do
      raise ArgumentError, "Function #{inspect(module)}.#{function}/#{arity} does not exist"
    end

    hook = prepare_hook(module, function, arity, func)

    add_hook(module, function, arity, hook, opts)

    debug("Added #{mode} hook")

    :ok
  end

  defp add_hook(module, function, arity, hook, opts) do
    mode = Keyword.get(opts, :mode, :local)

    case :ets.lookup(:repatch_state, {module, function, arity, self()}) do
      [] ->
        do_add_hook(module, function, arity, hook, mode)
        :ets.insert(:repatch_state, {{module, function, arity, self()}, [:patched, mode]})

      [{_, tags}] ->
        if :patched in tags and not Keyword.get(opts, :force, false) do
          raise ArgumentError,
                "Function #{inspect(module)}.#{function}/#{arity} is already patched"
        else
          do_add_hook(module, function, arity, hook, mode)
          tags = [mode | tags -- [mode]]
          :ets.insert(:repatch_state, {{module, function, arity, self()}, tags})
        end
    end
  end

  defp do_add_hook(module, function, arity, hook, mode) do
    case mode do
      :local ->
        add_local_hook(module, function, arity, hook)

      :shared ->
        add_shared_hook(module, function, arity, hook)

      :global ->
        add_global_hook(module, function, arity, hook)
    end
  end

  @typedoc """
  Options passed in the `restore/4` function.

  * `mode` (`:local` | `:shared` | `:global`) — What mode to remove the patch in. See `t:mode/0` for more info. Defaults to `:local`.
  """
  @type restore_option() :: {:mode, mode()}

  @doc """
  Removes any patch or fake on the specified function.
  See `t:restore_option/0` for available options.
  """
  @spec restore(module(), atom(), arity(), [restore_option()]) :: :ok
  def restore(module, function, arity, opts \\ []) do
    mode = Keyword.get(opts, :mode, :local)

    case mode do
      :local ->
        remove_local_hook(module, function, arity)

      :shared ->
        remove_shared_hook(module, function, arity)

      :global ->
        remove_global_hook(module, function, arity)
    end

    with [{_, tags}] <- :ets.lookup(:repatch_state, {module, function, arity, self()}) do
      tags = tags -- [:patched, :local, :shared, :global]
      :ets.insert(:repatch_state, {{module, function, arity, self()}, tags})
    end

    :ok
  end

  @typedoc """
  Options passed in the `allow/3` function.

  * `force` (boolean) — Whether to override existing allowance on the allowed process or not. Defaults to `false`.
  """
  @type allow_option :: {:force, boolean()}

  @doc """
  Enables the `allowed` process to use the patch from `owner` process.
  Works only for patches in shared mode.
  See `t:allow_option/0` for available options.
  """
  @spec allow(pid(), pid(), [allow_option()]) :: :ok
  def allow(owner, allowed, opts \\ []) do
    unless :persistent_term.get(:repatch_shared_hooks_enabled, true) do
      raise ArgumentError, "Shared hooks are disabled!"
    end

    final_owner =
      case :ets.lookup(:repatch_shared_allowances, owner) do
        [] ->
          owner

        [{_, final_owner}] ->
          final_owner
      end

    if final_owner == allowed do
      if allowed == owner do
        raise ArgumentError, "Can't use allowance on the same process #{inspect(allowed)}"
      else
        raise ArgumentError,
              "Cyclic allowance detected! #{inspect([allowed, owner, final_owner])}"
      end
    end

    unless :ets.insert_new(:repatch_shared_allowances, {allowed, final_owner}) do
      if Keyword.get(opts, :force, false) do
        :ets.delete(:repatch_shared_allowances, allowed)
        :ets.insert(:repatch_shared_allowances, {allowed, final_owner})
      else
        raise ArgumentError,
              "Allowance is already present for the specified process #{inspect(allowed)}"
      end
    end

    debug("#{inspect(allowed)} Set owner to #{inspect(owner)}")

    :ok
  end

  @doc """
  Lists all allowances of specified process (or `self()` by default).
  Works only when shared mode is enabled.

  Please note that deep allowances are returned as the final allowed process.
  """
  @spec allowances(pid()) :: [pid()]
  def allowances(pid \\ self()) do
    :repatch_shared_allowances
    |> :ets.match({:"$1", pid})
    |> Enum.concat()
  end

  @doc """
  Lists current owner of the allowed process (or `self()` by default).
  Works only when shared mode is enabled.

  Please note that deep allowances are returned as the final owner of the process.
  """
  @spec owner(pid()) :: pid() | nil
  def owner(pid \\ self()) do
    case :ets.lookup(:repatch_shared_allowances, pid) do
      [{_, owner}] -> owner
      _ -> nil
    end
  end

  @doc """
  For debugging purposes only. Returns list of tags which indicates patch state of the specified function.
  """
  @spec info(module(), atom(), arity(), pid()) :: [tag()]
  @spec info(module(), atom(), arity(), :any) :: %{pid() => [tag()]}
  def info(module, function, arity, pid \\ self())

  def info(module, function, arity, pid) when is_pid(pid) do
    case :ets.lookup(:repatch_state, {module, function, arity, pid}) do
      [{_, tags}] -> tags
      _ -> []
    end
  end

  def info(module, function, arity, :any) do
    results = :ets.match_object(:repatch_state, {{module, function, arity, :_}, :_})
    Map.new(results, fn {{_, _, _, pid}, tags} -> {pid, tags} end)
  end

  @typedoc """
  Options passed in the `repatched?/4` function.

  * `mode` (`:local` | `:shared` | `:global` | `:any`) — What mode to check the patch in. See `t:mode/0` for more info. Defaults to `:any`.
  """
  @type repatched_check_option :: {:mode, mode() | :any}

  @doc """
  Checks if function is patched in any (or some specific) mode.
  """
  @spec repatched?(module(), atom(), arity(), [repatched_check_option()]) :: boolean()
  def repatched?(module, function, arity, opts \\ []) do
    case Keyword.get(opts, :mode, :any) do
      :any ->
        :patched in info(module, function, arity)

      mode ->
        tags = info(module, function, arity)
        :patched in tags and mode in tags
    end
  end

  @typedoc """
  Options passed in the `called?/4` function. When multiple options are specified, they are combined in logical AND fashion.

  * `by` (`:any` | pid) — what process called the function. Defaults to `self()`.
  * `at_least` (`:once` | integer) — at least how many times the function was called. Defaults to `:once`.
  * `exactly` (`:once` | integer) — exactly how many times the function was called.
  * `before` (`:erlang.monotonic_time/0` timestamp) — upper boundary of when the function was called.
  * `after` (`:erlang.monotonic_time/0` timestamp) — lower boundary of when the function was called.
  """
  @type called_check_option ::
          {:by, pid() | :any}
          | {:at_least, :once | pos_integer()}
          | {:exactly, :once | pos_integer()}
          | {:after, monotonic_time_native :: integer()}
          | {:before, monotonic_time_native :: integer()}

  @doc """
  Checks if the function call is present in the history or not.
  Works with exact match on arguments or just an arity.
  Works only when history is enabled in setup.
  See `t:called_check_option/0` for available options.
  """
  @spec called?(module(), atom(), arity() | [term()], [called_check_option()]) :: boolean()
  def called?(module, function, arity_or_args, opts \\ []) do
    exactly = intify(Keyword.get(opts, :exactly))
    at_least = intify(Keyword.get(opts, :at_least, 1))
    afterr = Keyword.get(opts, :after)
    before = Keyword.get(opts, :before)
    by = Keyword.get(opts, :by, self())

    cond do
      not :persistent_term.get(:repatch_history_enabled, true) ->
        raise ArgumentError, "History disabled"

      before && afterr && afterr > before ->
        raise ArgumentError, "Can't have after more than before. Got #{afterr} > #{before}"

      exactly && at_least && at_least > exactly ->
        raise ArgumentError,
              "When specifying exactly and at_least options, make sure that " <>
                "exactly is always less than at_least. Got #{at_least} > #{exactly}"

      !(exactly || at_least) ->
        raise ArgumentError, "At least one parameter of exactly and at_least is required"

      true ->
        :ok
    end

    {arity, args} =
      case arity_or_args do
        args when is_list(args) ->
          {length(args), args}

        arity when is_integer(arity) and arity >= 0 ->
          {arity, :_}
      end

    pid =
      case by do
        :any ->
          :_

        pid when is_pid(pid) ->
          pid

        other ->
          raise ArgumentError, "Expected by option to be pid or `:any`. Got #{inspect(other)}"
      end

    module
    |> called_pattern(function, arity, pid, args, afterr, before)
    |> called_one(exactly, at_least)
  end

  defp called_pattern(module, function, arity, pid, args, nil, nil) do
    {{{module, function, arity, pid}, :_, args}, [], [:"$$"]}
  end

  defp called_pattern(module, function, arity, pid, args, nil, before) do
    {{{module, function, arity, pid}, :"$1", args}, [{:"=<", :"$1", before}], [:"$$"]}
  end

  defp called_pattern(module, function, arity, pid, args, afterr, nil) do
    {{{module, function, arity, pid}, :"$1", args}, [{:>=, :"$1", afterr}], [:"$$"]}
  end

  defp called_pattern(module, function, arity, pid, args, afterr, before) do
    {{{module, function, arity, pid}, :"$1", args},
     [{:>=, :"$1", afterr}, {:"=<", :"$1", before}], [:"$$"]}
  end

  defp called_one(key_pattern, nil, at_least) do
    called_at_least(key_pattern, at_least)
  end

  defp called_one(key_pattern, exactly, _at_least) do
    called_exactly(key_pattern, exactly)
  end

  defp intify(nil), do: nil
  defp intify(:once), do: 1
  defp intify(i) when is_integer(i) and i > 0, do: i

  defp intify(other) do
    raise ArgumentError, "Expected positive integer or `:once` atom. Got #{inspect(other)}"
  end

  defp called_exactly(pattern, count) do
    case :ets.select(:repatch_history, [pattern], count + 1) do
      {list, :"$end_of_table"} -> length(list) == count
      _ -> false
    end
  end

  defp called_at_least(pattern, count) do
    case :ets.select(:repatch_history, [pattern], count) do
      {list, _} -> length(list) == count
      _ -> false
    end
  end

  defp await_recompilation(module) do
    case :ets.lookup(:repatch_module_states, module) do
      [{_, :recompiling}] ->
        receive after: (10 -> [])
        await_recompilation(module)

      _ ->
        :ok
    end
  end

  defp add_local_hook(module, function, arity, hook) do
    :erlang.put({:repatch_hooks, module, function, arity}, hook)
  end

  defp add_shared_hook(module, function, arity, hook) do
    if :persistent_term.get(:repatch_shared_hooks_enabled, true) do
      :erlang.put({:repatch_shared_hooks, module, function, arity}, hook)
      :ets.insert(:repatch_shared_hooks, {{module, function, arity, self()}, hook})
    else
      raise ArgumentError, "Shared hooks disabled"
    end
  end

  defp add_global_hook(module, function, arity, hook) do
    if :persistent_term.get(:repatch_global_hooks_enabled, false) do
      :ets.insert(:repatch_global_hooks, {{module, function, arity}, self(), hook})
    else
      raise ArgumentError, "Global hooks disabled"
    end
  end

  defp remove_local_hook(module, function, arity) do
    :erlang.erase({:repatch_hooks, module, function, arity})
  end

  defp remove_shared_hook(module, function, arity) do
    if :persistent_term.get(:repatch_shared_hooks_enabled, true) do
      :erlang.erase({:repatch_shared_hooks, module, function, arity})
      :ets.delete(:repatch_shared_hooks, {module, function, arity, self()})
    else
      raise ArgumentError, "Shared hooks disabled"
    end
  end

  defp remove_global_hook(module, function, arity) do
    if :persistent_term.get(:repatch_global_hooks_enabled, false) do
      :ets.delete(:repatch_global_hooks, {module, function, arity})
    else
      raise ArgumentError, "Global hooks disabled"
    end
  end

  defp prepare_hook(_module, _function, _arity, hook) do
    fn args -> {:ok, apply(hook, args)} end
  end

  @doc false
  @spec dispatch(module(), atom(), arity(), [term()]) :: :pass | {:ok, term()}
  def dispatch(module, function, arity, args) do
    if :persistent_term.get(:repatch_history_enabled, true) do
      ts = :erlang.monotonic_time()
      :ets.insert(:repatch_history, {{module, function, arity, self()}, ts, args})
      debug("Inserted history #{ts}")
    end

    case :erlang.get(:repatch_bypass_hooks) do
      no when no in ~w[undefined false]a ->
        case :erlang.get({:repatch_hooks, module, function, arity}) do
          :undefined ->
            dispatch_shared(module, function, arity, args)

          hook ->
            debug("Dispatched local")
            hook.(args)
        end

      true ->
        debug("Dispatched none")
        :pass
    end
  end

  defp dispatch_shared(module, function, arity, args) do
    if :persistent_term.get(:repatch_shared_hooks_enabled, true) do
      case :erlang.get({:repatch_shared_hooks, module, function, arity}) do
        :undefined ->
          case :ets.lookup(:repatch_shared_allowances, self()) do
            [] ->
              dispatch_global(module, function, arity, args)

            [{_, pid}] when is_pid(pid) ->
              dispatch_allowance(module, function, arity, args, pid)
          end

        hook ->
          debug("Dispatched shared")
          hook.(args)
      end
    else
      dispatch_global(module, function, arity, args)
    end
  end

  defp dispatch_allowance(module, function, arity, args, pid) do
    case :ets.lookup(:repatch_shared_hooks, {module, function, arity, pid}) do
      [] ->
        dispatch_global(module, function, arity, args)

      [{_, hook}] when is_function(hook) ->
        debug("Dispatched allowance with owner #{inspect(pid)}")
        hook.(args)
    end
  end

  defp dispatch_global(module, function, arity, args) do
    if :persistent_term.get(:repatch_global_hooks_enabled, false) do
      case :ets.lookup(:repatch_global_hooks, {module, function, arity}) do
        [] ->
          :pass

        [{_, _, hook}] ->
          debug("Dispatched global")
          hook.(args)
      end
    else
      :pass
    end
  end
end
