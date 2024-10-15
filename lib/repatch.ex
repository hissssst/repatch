defmodule Repatch do
  @moduledoc """
  Final word in Elixir testing
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
        IO.puts("#{inspect(self())} #{unquote(message)}")
      end
    end
  else
    defmacrop debug(_), do: nil
  end

  @type setup_option ::
          recompile_option()
          | {:enable_global, boolean()}
          | {:enable_shared, boolean()}
          | {:enable_history, boolean()}
          | {:recompile, module() | [module()]}

  @type mode :: :local | :shared | :global

  @type tag :: :patched | mode()

  @type recompile_option :: {:ignore_forbidden_module, boolean()}

  @spec setup([setup_option()]) :: :ok
  def setup(opts \\ []) do
    global_hooks_enabled = Keyword.get(opts, :enable_global)
    shared_hooks_enabled = Keyword.get(opts, :enable_shared)
    history_enabled = Keyword.get(opts, :enable_history)

    :ets.new(:repatch_module_states, [:set, :named_table, :public])
    :ets.new(:repatch_global_lock, [:set, :named_table, :public])
    :ets.new(:repatch_state, [:set, :named_table, :public])

    case global_hooks_enabled do
      nil ->
        :ok

      true ->
        :ets.new(:repatch_global_hooks, [:set, :named_table, :public])
        :persistent_term.put(:repatch_global_hooks_enabled, true)

      false ->
        :persistent_term.put(:repatch_global_hooks_enabled, false)
    end

    case shared_hooks_enabled do
      nil ->
        :ets.new(:repatch_shared_hooks, [:set, :named_table, :public])
        :ets.new(:repatch_shared_allowances, [:set, :named_table, :public])

      true ->
        :ets.new(:repatch_shared_hooks, [:set, :named_table, :public])
        :ets.new(:repatch_shared_allowances, [:set, :named_table, :public])
        :persistent_term.put(:repatch_shared_hooks_enabled, true)

      false ->
        :persistent_term.put(:repatch_shared_hooks_enabled, false)
    end

    case history_enabled do
      nil ->
        :ets.new(:repatch_history, [:duplicate_bag, :named_table, :public])

      true ->
        :ets.new(:repatch_history, [:duplicate_bag, :named_table, :public])
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

    :ok
  end

  @type spy_option :: recompile_option() | {:by, pid()}

  @spec spy(module(), [spy_option()]) :: :ok
  def spy(module, opts \\ []) do
    pid = Keyword.get(opts, :by, self())
    recompile(module, opts)
    cleanup_history(pid)
    :ok
  end

  @type fake_option :: recompile_option() | {:mode, mode()}

  @spec fake(module(), module(), [fake_option()]) :: :ok
  def fake(real_module, fake_module, opts \\ [])

  def fake(m, m, _opts) do
    raise ArgumentError, "Can't fake module with itself #{inspect(m)}"
  end

  def fake(real_module, fake_module, opts) do
    exports = real_module.module_info(:exports)
    recompile(real_module, opts)
    mode = Keyword.get(opts, :mode, :local)

    for {function, arity} <- exports do
      hook = fn args -> {:ok, apply(fake_module, function, args)} end
      add_hook(real_module, function, arity, hook, mode)
    end

    :ok
  end

  defmacro real({{:., _dotmeta, [_module, _function]}, _meta, _args} = call) do
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
    raise CompileError,
      description:
        "Expected call like Module.function(1, 2, 3). Got #{Code.format_string!(Macro.to_string(other))}",
      line: __CALLER__.line,
      file: __CALLER__.file
  end

  defmacro super({{:., _dotmeta, [module, function]}, meta, args}) do
    super_function = Recompiler.super_name(function)
    {:apply, meta, [module, super_function, args]}
  end

  defmacro super(other) do
    raise CompileError,
      description:
        "Expected call like Module.function(1, 2, 3). Got #{Code.format_string!(Macro.to_string(other))}",
      line: __CALLER__.line,
      file: __CALLER__.file
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

  @type patch_option ::
          recompile_option()
          | {:mode, :local | :shared | :global}
          | {:force, boolean()}

  @spec patch(module(), atom(), [patch_option()], function()) :: :ok
  def patch(module, function, opts \\ [], func) do
    recompile(module, opts)

    arity =
      func
      |> :erlang.fun_info()
      |> Keyword.fetch!(:arity)

    unless {function, arity} in module.module_info(:exports) do
      raise ArgumentError, "Function #{inspect(module)}.#{function}/#{arity} does not exist"
    end

    mode = Keyword.get(opts, :mode, :local)
    hook = prepare_hook(module, function, arity, func)

    case :ets.lookup(:repatch_state, {module, function, arity, self()}) do
      [] ->
        add_hook(module, function, arity, hook, mode)
        :ets.insert(:repatch_state, {{module, function, arity, self()}, [:patched, mode]})

      [{_, tags}] ->
        if :patched in tags and not Keyword.get(opts, :force) do
          raise ArgumentError,
                "Function #{inspect(module)}.#{function}/#{arity} is already patched"
        else
          add_hook(module, function, arity, hook, mode)
          tags = [mode | tags -- [mode]]
          :ets.insert(:repatch_state, {{module, function, arity, self()}, tags})
        end
    end

    debug("Added #{mode} hook")

    :ok
  end

  defp add_hook(module, function, arity, hook, mode) do
    case mode do
      :local ->
        add_local_hook(module, function, arity, hook)

      :shared ->
        add_shared_hook(module, function, arity, hook)

      :global ->
        add_global_hook(module, function, arity, hook)
    end
  end

  @type restore_option() :: {:mode, mode()}

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

  @type allow_option :: {:force, boolean()}

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

    if Keyword.get(opts, :force, false) do
      :ets.insert(:repatch_shared_allowances, {allowed, final_owner})
    else
      unless :ets.insert_new(:repatch_shared_allowances, {allowed, final_owner}) do
        raise ArgumentError,
              "Allowance is already present for the specified process #{inspect(allowed)}"
      end
    end

    :ok
  end

  @spec allowances(pid()) :: [pid()]
  def allowances(pid \\ self()) do
    :repatch_shared_allowances
    |> :ets.match({:"$1", pid})
    |> Enum.concat()
  end

  @spec owner(pid()) :: pid() | nil
  def owner(pid \\ self()) do
    case :ets.lookup(:repatch_shared_allowances, pid) do
      [{_, owner}] -> owner
      _ -> nil
    end
  end

  @spec info(module(), atom(), arity(), pid()) :: [tag()]
  def info(module, function, arity, pid \\ self()) do
    case :ets.lookup(:repatch_state, {module, function, arity, pid}) do
      [{_, tags}] -> tags
      _ -> []
    end
  end

  @type repatched_check_option :: {:mode, mode() | :any}

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

  @type called_check_option ::
          {:by, pid() | :any}
          | {:at_least, :once | pos_integer()}
          | {:exactly, :once | pos_integer()}
          | {:after, monotonic_time_native :: integer()}
          | {:before, monotonic_time_native :: integer()}

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
                "at_least is always less than at_least. Got #{at_least} > #{exactly}"

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
      :erlang.put({:repatch_hooks, module, function, arity}, hook)
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
      :erlang.erase({:repatch_hooks, module, function, arity})
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
      case :erlang.get({:repatch_shared_hook, module, function, arity}) do
        :undefined ->
          case :erlang.get(:repatch_shared_allowance) do
            pid when is_pid(pid) ->
              dispatch_allowance(module, function, arity, args, pid)

            :undefined ->
              case :ets.lookup(:repatch_shared_allowances, self()) do
                [] ->
                  dispatch_global(module, function, arity, args)

                [{_, pid}] when is_pid(pid) ->
                  :erlang.put(:repatch_shared_allowance, pid)
                  dispatch_allowance(module, function, arity, args, pid)
              end
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
        debug("Dispatched allowance")
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
