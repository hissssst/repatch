defmodule Repatch do
  @external_resource Path.join([__DIR__, "../README.md"])

  @moduledoc """
  #{@external_resource |> File.read!() |> String.split("<!-- MDOC -->") |> tl() |> hd()}
  """

  alias Repatch.Recompiler
  import :erlang, only: [atom_to_binary: 1]

  @forbidden_modules [
    :code,
    :erlang,
    :ets,
    :persistent_term,
    Agent,
    Enum,
    Keyword,
    Map,
    Repatch,
    Repatch.ExUnit,
    Repatch.Recompiler
  ]

  # Macro for debugging. It is designed to be thin, because we want to keep repatch
  # runtime overhead as thin as possible and Logger or anything with runtime check
  # is a bad fit here

  debugging? = false

  if debugging? do
    defmacrop debug(message) do
      quote do
        IO.puts("#{inspect(self())} | #{unquote(message)}")
        []
      end
    end
  else
    defmacrop debug(_), do: []
  end

  @typedoc """
  Options passed in the `setup/1` function.

  * `enable_global` (boolean) — Whether to allow global mocks in test suites. Defaults to `false`.
  * `enable_shared` (boolean) — Whether to allow shared mocks in test suites. Defaults to `true`.
  * `enable_history` (boolean) — Whether to enable calls history tracking. Defaults to `true`.
  * `recompile` (list of modules) — What modules should be recompiled before test starts. Modules are recompiled lazily by default. Defaults to `[]`.
  * `ignore_forbidden_module` (boolean) — Whether to ignore the warning about forbidden module being recompiled. Works only when `recompile` is specified. Defaults to `false`.
  * `cover` (boolean) — Detected automatically by coverage tool, use with caution. Sets the `line_counters` native coverage mode.
  """
  @type setup_option ::
          recompile_option()
          | {:enable_global, boolean()}
          | {:enable_shared, boolean()}
          | {:enable_history, boolean()}
          | {:recompile, module() | [module()]}

  @typedoc """
  Mode of the patch, fake or application env isolation. These modes
  define the levels of isolation of the patches:

  * `:local` — Patches will work only in the process which set the patches
  * `:shared` — Patches will work only in the process which set the patches, spawned tasks or allowed processes. See `Repatch.allow/2`.
  * `:global` — Patches will work in all processes.

  Please check out "Isolation modes" doc for more information on details.
  """
  @type mode :: :local | :shared | :global

  @typedoc """
  Debug metadata tag of the function. Declares if the function is patched
  and what mode was used for the patch.
  """
  @type tag :: :patched | mode()

  @typedoc """
  Options passed in all functions which trigger module recompilation

  * `ignore_forbidden_module` (boolean) — Whether to ignore the warning about forbidden module being recompiled.
  * `recompile_only` (list of {module, function, arity} tuples) — Only these functions will be recompiled in this module or modules.
  * `recompile_except` (list of {module, function, arity} tuples) — All functions except specified will be recompiled in this module or modules.
  * `module_binary` (binary) — The BEAM binary of the module to recompile
  """
  @type recompile_option ::
          {:ignore_forbidden_module, boolean()}
          | {:module_binary, binary()}
          | {:recompile_only, [{module(), atom(), arity()}]}
          | {:recompile_except, [{module(), atom(), arity()}]}

  @doc """
  Setup function. Use it only once per test suite.
  See `t:setup_option/0` for available options.

  ## Example

      iex> Repatch.setup(enable_shared: false)

  It is suggested to be put in the `test_helper.exs` after the `ExUnit.start()` line
  """
  @spec setup([setup_option()]) :: :ok
  def setup(opts \\ []) do
    cover =
      Keyword.get_lazy(opts, :cover, fn -> :persistent_term.get(:repatch_line_counters, false) end)

    if cover && function_exported?(:code, :set_coverage_mode, 1) do
      apply(:code, :set_coverage_mode, [:line_counters])
    end

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

    # Doing this without Task, because we want to let users patch Task

    caller = self()

    to_await =
      for module <- List.wrap(Keyword.get(opts, :recompile, [])) do
        ref = make_ref()

        spawn_link(fn ->
          recompile(module, opts)
          send(caller, {module, ref})
        end)

        {module, ref}
      end

    for {module, ref} <- to_await do
      receive do
        {^module, ^ref} -> :ok
      after
        30_000 ->
          raise "Recompilation is taking more than 30 seconds"
      end
    end

    debug("setup successful")

    :ok
  end

  @doc false
  @spec setup_table(atom(), [any()]) :: :ok
  def setup_table(name, options) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, options)
        :ok

      _ ->
        :ok
    end
  end

  @doc false
  @spec delete_all_objects(atom()) :: :ok
  def delete_all_objects(name) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.delete_all_objects(name)
        :ok

      _ ->
        :ok
    end
  end

  @doc false
  @spec recompile(module(), [recompile_option() | any()]) :: :ok
  def recompile(module, opts \\ []) do
    if module in @forbidden_modules and not Keyword.get(opts, :ignore_forbidden_module, false) do
      raise ArgumentError,
            "Module #{inspect(module)} is a forbidden to patch module, because it may interfere with the Repatch logic"
    end

    debug("Recompiling #{inspect(module)}")

    case :ets.lookup(:repatch_module_states, module) do
      [{_, :recompiling}] ->
        debug("#{inspect(module)} awaiting recompilation")
        await_recompilation(module)

      [{_, {:recompiled, _, _}}] ->
        debug("#{inspect(module)} found recompiled")
        :ok

      [] ->
        if :ets.insert_new(:repatch_module_states, {module, :recompiling}) do
          try do
            case Recompiler.recompile(module, opts) do
              {:ok, bin, filename} ->
                :ets.insert(:repatch_module_states, {module, {:recompiled, bin, filename}})
                debug("Recompiled #{inspect(module)}")
                :ok

              {:error, :nofile} ->
                raise ArgumentError, "Module #{inspect(module)} does not exist"

              {:error, :binary_unavailable} ->
                raise ArgumentError, "Binary for module #{inspect(module)} is unavailable"
            end
          rescue
            error ->
              :ets.delete(:repatch_module_states, module)
              reraise error, __STACKTRACE__
          end
        else
          await_recompilation(module)
        end
    end
  end

  @doc """
  Cleans up current test process (or any other process) Repatch-state.

  ## Example

      iex> Repatch.patch(DateTime, :utc_now, fn -> :ok end)
      iex> DateTime.utc_now()
      :ok
      iex> Repatch.called?(DateTime, :utc_now, 0)
      true
      iex> Repatch.cleanup()
      iex> Repatch.called?(DateTime, :utc_now, 0)
      false
      iex> %DateTime{} = DateTime.utc_now()

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
  modules back to their original bytecode, disabling history collection on them.

  ## Example

      iex> Repatch.patch(DateTime, :utc_now, fn -> :ok end)
      iex> DateTime.utc_now()
      :ok
      iex> Repatch.restore_all()
      iex> %DateTime{} = DateTime.utc_now()

  It is not recommended to be called during testing and it is suggested to be used only
  when Repatch is used in iex session.
  """
  @spec restore_all() :: :ok
  def restore_all do
    :repatch_module_states
    |> :ets.tab2list()
    |> Enum.each(fn {module, state} ->
      case state do
        {:recompiled, original_binary, original_filename} ->
          Recompiler.load_binary(module, original_filename, original_binary)

        :recompiling ->
          await_recompilation(module)

        _ ->
          :ok
      end
    end)

    delete_all_objects(:repatch_module_states)
    delete_all_objects(:repatch_state)
    delete_all_objects(:repatch_history)
    delete_all_objects(:repatch_global_hooks)
    delete_all_objects(:repatch_shared_hooks)
    delete_all_objects(:repatch_shared_allowances)

    :ok
  end

  @typedoc """
  Options passed in the `spy/2` function.

  * `by` (pid) — What process history to clean. Defaults to `self()`.
  * `ignore_forbidden_module` (boolean) — Whether to ignore the warning about forbidden module is being spied. Defaults to `false`.
  """
  @type spy_option :: recompile_option() | {:by, pid()}

  @doc """
  Tracks calls to the specified module.

  Be aware that it recompiles the module if it was not patched or spied on before, which may take some time.

  ## Example

      iex> Repatch.spy(DateTime)
      iex> DateTime.utc_now()
      iex> Repatch.called?(DateTime, :utc_now, 0)
      true
      iex> Repatch.spy(DateTime)
      iex> Repatch.called?(DateTime, :utc_now, 0)
      false

  If spy is called on the same module for more than one time, it will clear the history of calls.
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
  * `mode` (`:local` | `:shared` | `:global`) — What mode to use for the patch. See `t:mode/0` for more info. Defaults to `:local`.
  """
  @type fake_option :: patch_option()

  @doc """
  Replaces functions implementation of the `real_module` with functions
  of the `fake_module`.

  See `t:fake_option/0` for available options.

  ## Example

      iex> ~U[2024-10-20 13:31:59.342240Z] != DateTime.utc_now()
      true
      iex> defmodule FakeDateTime do
      ...>   def utc_now do
      ...>     ~U[2024-10-20 13:31:59.342240Z]
      ...>   end
      ...> end
      iex> Repatch.fake(DateTime, FakeDateTime)
      iex> DateTime.utc_now()
      iex> ~U[2024-10-20 13:31:59.342240Z] == DateTime.utc_now()
      true
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

  defp maybe_raise_repatch_generated(function, env, name) do
    if Recompiler.generated?(function) do
      raise CompileError,
        description: "Can't call #{name}/1 on Repatch-generated functions. Got #{function}",
        line: env.line,
        file: env.file
    end
  end

  defp maybe_raise_repatch_generated(function, name) do
    if Recompiler.generated?(function) do
      raise ArgumentError, "Can't call #{name}/1 on Repatch-generated functions. Got #{function}"
    end
  end

  defp maybe_raise_non_existing(module, function, function_string, arity) do
    exists =
      Enum.any?(module.module_info(:exports), fn
        {f, ^arity} -> atom_to_binary(f) == function_string
        _ -> false
      end)

    unless exists do
      raise UndefinedFunctionError,
        module: module,
        function: function,
        arity: arity,
        message: "Can't find patch"
    end
  end

  @doc """
  Function version of the `real/1` macro. Please prefer to use macro in tests, since
  it is slightly more efficient

  ## Example

      iex> Repatch.patch(DateTime, :utc_now, fn _calendar -> :repatched end)
      iex> DateTime.utc_now()
      :repatched
      iex> %DateTime{} = Repatch.real(DateTime, :utc_now, [])
  """
  @spec real(module(), atom(), [term()]) :: any()
  def real(module, function, args) do
    maybe_raise_repatch_generated(function, :real)
    :erlang.put(:repatch_bypass_hooks, true)
    apply(module, function, args)
  after
    :erlang.erase(:repatch_bypass_hooks)
  end

  @doc """
  Use this on a call which would result only to unpatched versions of functions to be called on the whole stack of calls.
  Works only on calls in `Module.function(arg0, arg1, arg2)` format.

  ## Example

      iex> Repatch.patch(DateTime, :utc_now, fn _calendar -> :repatched end)
      iex> DateTime.utc_now()
      :repatched
      iex> %DateTime{} = Repatch.real(DateTime.utc_now())
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
  Function version of the `Repatch.super/1` macro. Please try to use the macro version,
  since it is slightly more efficient.

  ## Example

      iex> Repatch.patch(DateTime, :utc_now, fn _calendar -> :repatched end)
      iex> DateTime.utc_now()
      :repatched
      iex> Repatch.super(DateTime, :utc_now, [])
      :repatched
      iex> %DateTime{} = Repatch.super(DateTime, :utc_now, [Calendar.ISO])
  """
  @spec super(module(), atom(), [term()]) :: any()
  def super(module, function, args) do
    maybe_raise_repatch_generated(function, :super)

    maybe_raise_non_existing(
      module,
      function,
      Recompiler.super_name_string(function),
      length(args)
    )

    super_function = Recompiler.super_name(function)
    apply(module, super_function, args)
  end

  @doc """
  Use this on a call which would result only on one unpatched version of the function to be called.
  Works only on calls in `Module.function(arg0, arg1, arg2)` format.

  ## Example

      iex> Repatch.patch(DateTime, :utc_now, fn _calendar -> :repatched end)
      iex> DateTime.utc_now()
      :repatched
      iex> Repatch.super(DateTime.utc_now())
      :repatched
      iex> %DateTime{} = Repatch.super(DateTime.utc_now(Calendar.ISO))
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
  Function version of the `private/1` macro. Please try to use the macro version
  when possible, because macro has slightly better performance
  """
  @spec private(module(), atom(), [term()]) :: any()
  def private(module, function, args) do
    maybe_raise_repatch_generated(function, :private)

    maybe_raise_non_existing(
      module,
      function,
      Recompiler.private_name_string(function),
      length(args)
    )

    private_function = Recompiler.private_name(function)
    apply(module, private_function, args)
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
  Opaque value returned from `notify/4` or `notify/2`.
  Can be used to receive the notification about the function call.
  """
  @opaque notify_ref :: {module(), atom(), arity(), reference()}

  @doc """
  Patches a function to send the message to the calling process
  every time this function is successfully executed. Result
  of `notify/4` can be used to be receivied on.

  ## Example

      iex> notification = Repatch.notify(DateTime, :utc_now, 0)
      iex> receive do ^notification -> :got after 0 -> :none end
      :none
      iex> DateTime.utc_now()
      iex> receive do ^notification -> :got after 0 -> :none end
      :got

  If you want to stop receiving notifications, you can call `restore/4`.

  It is recommended to not use this function and instead use `m::trace` module
  """
  @doc since: "1.6.0"
  @spec notify(module(), atom(), arity() | [term()], [patch_option()]) :: notify_ref()
  def notify(module, function, args_or_arity, opts \\ []) do
    recompile(module, opts)
    owner = self()

    arity =
      case args_or_arity do
        arity when is_integer(arity) ->
          arity

        args when is_list(args) ->
          length(args)
      end

    opaque_ref = {module, function, arity, make_ref()}

    hook =
      case args_or_arity do
        arity when is_integer(arity) ->
          fn args ->
            result = __MODULE__.super(module, function, args)
            send(owner, opaque_ref)
            {:ok, result}
          end

        args when is_list(args) ->
          fn called_args ->
            case called_args do
              ^args ->
                result = __MODULE__.super(module, function, called_args)
                send(owner, opaque_ref)
                {:ok, result}

              _ ->
                {:ok, __MODULE__.super(module, function, called_args)}
            end
          end
      end

    add_hook(module, function, arity, hook, opts)
    opaque_ref
  end

  @doc """
  Patches a function to send the message to the calling process
  every time this function is successfully executed. Result
  of `notify/2` can be used to be receivied on.

  ## Example

      iex> notification = Repatch.notify DateTime.utc_now()
      iex> receive do ^notification -> :got after 0 -> :none end
      :none
      iex> DateTime.utc_now()
      iex> receive do ^notification -> :got after 0 -> :none end
      :got
  """
  @doc since: "1.6.0"
  defmacro notify(dotcall, opts \\ [])

  defmacro notify({{:., _, [module, function]}, _meta, args}, opts) do
    arity = length(args)

    quote do
      module = unquote(module)
      function = unquote(function)
      opts = unquote(opts)
      unquote(__MODULE__).recompile(module, opts)
      owner = self()
      opaque_ref = {module, function, unquote(arity), make_ref()}

      hook =
        fn called_args ->
          case called_args do
            unquote(args) ->
              result = unquote(__MODULE__).super(module, function, called_args)
              send(owner, opaque_ref)
              {:ok, result}

            _ ->
              {:ok, unquote(__MODULE__).super(module, function, called_args)}
          end
        end

      unquote(__MODULE__).add_hook(module, function, unquote(arity), hook, opts)
      opaque_ref
    end
  end

  defmacro notify(quoted, _opts) do
    raise_wrong_dotcall(quoted)
  end

  @typedoc """
  Options passed in the `patch/4` function.

  * `ignore_forbidden_module` (boolean) — Whether to ignore the warning about forbidden module is being spied. Defaults to `false`.
  * `force` (boolean) — Whether to override existing patches. Defaults to `false`.
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

  ## Example

      iex> ~U[2024-10-20 13:31:59.342240Z] != DateTime.utc_now()
      true
      iex> Repatch.patch(DateTime, :utc_now, fn -> ~U[2024-10-20 13:31:59.342240Z] end)
      iex> DateTime.utc_now()
      ~U[2024-10-20 13:31:59.342240Z]

  Be aware that it recompiles the module if it was not patched before, which may take some time.

  And it is also recommended to not patch functions which can be changed in the future, since
  every patch is an implicit dependency on the internals of implementation.
  """
  @spec patch(module(), atom(), [patch_option()], function()) :: :ok
  def patch(module, function, opts \\ [], func) do
    recompile(module, opts)

    arity =
      func
      |> :erlang.fun_info()
      |> Keyword.fetch!(:arity)

    case extract_export_type(module, function, arity) do
      :macro ->
        hook = prepare_hook(module, function, arity, func)
        add_hook(module, :"MACRO-#{function}", arity, hook, opts)

      :function ->
        hook = prepare_hook(module, function, arity, func)
        add_hook(module, function, arity, hook, opts)

      nil ->
        raise ArgumentError, "Function #{inspect(module)}.#{function}/#{arity} does not exist"
    end

    :ok
  end

  defp extract_export_type(module, function, arity) do
    macro_name = "MACRO-#{function}"
    super_name = Recompiler.super_name_string(function)

    Enum.find_value(module.module_info(:exports), fn {function, function_arity} ->
      case atom_to_binary(function) do
        ^macro_name when function_arity == arity ->
          :macro

        ^super_name when function_arity == arity ->
          :function

        _ ->
          false
      end
    end)
  end

  @doc false
  def add_hook(module, function, arity, hook, opts) do
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

    debug("Added #{mode} function hook")
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
  Removes any patch on the specified function.
  See `t:restore_option/0` for available options.

  ## Example

      iex> URI.encode_query(%{x: 123})
      "x=123"
      iex> Repatch.patch(URI, :encode_query, fn query -> inspect(query) end)
      iex> URI.encode_query(%{x: 123})
      "%{x: 123}"
      iex> Repatch.restore(URI, :encode_query, 1)
      iex> URI.encode_query(%{x: 123})
      "x=123"
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
      tags = tags -- [:patched, mode]
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

  ## Example

      iex> alias Repatch.Looper
      iex> require Repatch
      iex> pid = Looper.start_link()
      iex> Range.new(1, 3)
      1..3
      iex> Repatch.patch(Range, :new, [mode: :shared], fn l, r -> Enum.to_list(Repatch.super(Range.new(l, r))) end)
      iex> Range.new(1, 3)
      [1, 2, 3]
      iex> Looper.call(pid, Range, :new, [1, 3])
      1..3
      iex> Repatch.allow(self(), pid)
      iex> Looper.call(pid, Range, :new, [1, 3])
      [1, 2, 3]
  """
  @spec allow(
          pid() | GenServer.name() | {atom(), node()},
          pid() | GenServer.name() | {atom(), node()},
          [allow_option()]
        ) :: :ok
  def allow(owner, allowed, opts \\ []) do
    unless :persistent_term.get(:repatch_shared_hooks_enabled, true) do
      raise ArgumentError, "Shared hooks are disabled!"
    end

    owner = resolve_pid(owner)
    allowed = resolve_pid(allowed)

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

  ## Example

      iex> alias Repatch.Looper
      iex> require Repatch
      iex> pid1 = Looper.start_link()
      iex> pid2 = Looper.start_link()
      iex> Repatch.allowances()
      []
      iex> Repatch.allow(self(), pid1)
      iex> Repatch.allowances()
      [pid1]
      iex> Repatch.allow(pid1, pid2)
      iex> pid1 in Repatch.allowances() and pid2 in Repatch.allowances()
      true
      iex> Repatch.allowances(pid1)
      []
      iex> Repatch.allowances(pid2)
      []
  """
  @spec allowances(pid()) :: [pid()]
  def allowances(pid \\ self()) do
    :repatch_shared_allowances
    |> :ets.match({:"$1", pid})
    |> Enum.concat()
  end

  @doc """
  Returns current owner of the allowed process (or `self()` by default) if any.
  Works only when shared mode is enabled.

  Please note that deep allowances are returned as the final owner of the process.

  ## Example

      iex> alias Repatch.Looper
      iex> require Repatch
      iex> pid1 = Looper.start_link()
      iex> pid2 = Looper.start_link()
      iex> Repatch.owner(pid1)
      nil
      iex> Repatch.allow(self(), pid1)
      iex> Repatch.owner(pid1)
      self()
      iex> Repatch.allow(pid1, pid2)
      iex> Repatch.owner(pid2)
      self()
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

  ## Example

      iex> Repatch.patch(MapSet, :new, fn -> :not_a_mapset end)
      iex> Repatch.info(MapSet, :new, 0)
      [:patched, :local]
  """
  @spec info(module(), atom(), arity(), pid()) :: [tag()]
  @spec info(module(), atom(), arity(), :any) :: %{pid() => [tag()]}
  def info(module, function, arity, pid \\ self())

  def info(module, function, arity, :any) do
    results = :ets.match_object(:repatch_state, {{module, function, arity, :_}, :_})
    Map.new(results, fn {{_, _, _, pid}, tags} -> {pid, tags} end)
  end

  def info(module, function, arity, name) do
    pid = resolve_pid(name)

    case :ets.lookup(:repatch_state, {module, function, arity, pid}) do
      [{_, tags}] -> tags
      _ -> []
    end
  end

  @typedoc """
  Options passed in the `repatched?/4` function.

  * `mode` (`:local` | `:shared` | `:global` | `:any`) — What mode to check the patch in. See `t:mode/0` for more info. Defaults to `:any`.
  """
  @type repatched_check_option :: {:mode, mode() | :any}

  @doc """
  Checks if function is patched in any (or some specific) mode.

  ## Example

      iex> Repatch.repatched?(MapSet, :new, 0)
      false
      iex> Repatch.patch(MapSet, :new, fn -> :not_a_mapset end)
      iex> Repatch.repatched?(MapSet, :new, 0)
      true
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
  Options passed in the `history/1` function. When multiple options are specified, they are combined in logical AND fashion.

  * `by` (`t:GenServer.name/0` | `:any` | pid) — what process called the function. Defaults to `self()`.
  * `before` (`:erlang.monotonic_time/0` timestamp) — upper boundary of when the function was called.
  * `after` (`:erlang.monotonic_time/0` timestamp) — lower boundary of when the function was called.
  """
  @type history_option ::
          {:by, GenServer.name() | pid() | :any}
          | {:after, monotonic_time_native :: integer()}
          | {:before, monotonic_time_native :: integer()}
          | {:module, module()}
          | {:function, atom()}
          | {:arity, arity()}
          | {:args, [term()]}

  @typedoc """
  Options passed in the `called?/2` and `called?/4`. When multiple options are specified, they are combined in logical AND fashion.

  * `by` (`t:GenServer.name/0` | `:any` | pid) — what process called the function. Defaults to `self()`.
  * `at_least` (`:once` | integer) — at least how many times the function was called. Defaults to `:once`.
  * `exactly` (`:once` | integer) — exactly how many times the function was called.
  * `before` (`:erlang.monotonic_time/0` timestamp) — upper boundary of when the function was called.
  * `after` (`:erlang.monotonic_time/0` timestamp) — lower boundary of when the function was called.
  """
  @type called_check_option ::
          {:by, GenServer.name() | pid() | :any}
          | {:after, monotonic_time_native :: integer()}
          | {:before, monotonic_time_native :: integer()}
          | {:at_least, :once | pos_integer()}
          | {:exactly, :once | pos_integer()}

  @doc """
  Checks if the function call is present in the history or not.
  See `t:called_check_option/0` for available options.

  ## Example

      iex> Repatch.spy(Path)
      iex> Repatch.called?(Path, :join, 2)
      false
      iex> Path.join("left", "right")
      "left/right"
      iex> Repatch.called?(Path, :join, 2)
      true
      iex> Repatch.called?(Path, :join, 2, exactly: :once)
      true
      iex> Path.join("left", "right")
      "left/right"
      iex> Repatch.called?(Path, :join, 2, exactly: :once)
      false

  Works only when history is enabled in setup.
  Please make sure that module is spied on or at least patched before querying history on it.
  """
  @spec called?(module(), atom(), arity() | [term()], [called_check_option()]) :: boolean()
  def called?(module, function, arity_or_args, opts \\ []) do
    {exactly, at_least, afterr, before, pid} = parse_called_opts(opts)

    {arity, args} =
      case arity_or_args do
        args when is_list(args) ->
          {length(args), args}

        arity when is_integer(arity) and arity >= 0 ->
          {arity, :_}
      end

    module
    |> called_pattern(function, arity, pid, args, 1, afterr, before)
    |> called_one(exactly, at_least)
  end

  @doc false
  def parse_called_opts(opts) do
    {afterr, before, pid} = parse_history_opts(opts)

    exactly = intify(Keyword.get(opts, :exactly))
    at_least = intify(Keyword.get(opts, :at_least, 1))

    cond do
      exactly && at_least && at_least > exactly ->
        raise ArgumentError,
              "When specifying exactly and at_least options, make sure that " <>
                "exactly is always less than at_least. Got #{at_least} > #{exactly}"

      !(exactly || at_least) ->
        raise ArgumentError, "At least one parameter of exactly and at_least is required"

      true ->
        :ok
    end

    {exactly, at_least, afterr, before, pid}
  end

  defp parse_history_opts(opts) do
    afterr = Keyword.get(opts, :after)
    before = Keyword.get(opts, :before)
    by = Keyword.get(opts, :by, self())

    cond do
      not :persistent_term.get(:repatch_history_enabled, true) ->
        raise ArgumentError, "History disabled"

      before && afterr && afterr > before ->
        raise ArgumentError, "Can't have after more than before. Got #{afterr} > #{before}"

      true ->
        :ok
    end

    pid =
      case by do
        :any ->
          :_

        other ->
          resolve_pid(other)
      end

    {afterr, before, pid}
  end

  @doc """
  Checks if the function call is present in the history or not.
  First argument of this macro must be in a `Module.function(arguments)` format
  and `arguments` can be a pattern. It is also possible to specify a guard like in example.

  See `t:called_check_option/0` for available options.

  ## Example

      iex> Repatch.spy(Path)
      iex> Repatch.called? Path.split("path/to")
      false
      iex> Path.split("path/to")
      ["path", "to"]
      iex> Repatch.called? Path.split("path/to")
      true
      iex> Repatch.called? Path.split(string) when is_binary(string)
      true
      iex> Repatch.called? Path.split("path/to"), exactly: :once
      true
      iex> Path.split("path/to")
      ["path", "to"]
      iex> Repatch.called? Path.split("path/to"), exactly: :once
      false

  Works only when history is enabled in setup.
  Please make sure that module is spied on or at least patched before querying history on it.
  """
  @doc since: "1.6.0"
  defmacro called?(dotcall, opts \\ []) do
    {module, function, args, guard} =
      case dotcall do
        {{:., _dotmeta, [module, function]}, _meta, args} ->
          {module, function, args, true}

        {:when, _, [{{:., _dotmeta, [module, function]}, _meta, args}, guard]} ->
          {module, function, args, guard}

        quoted ->
          raise_wrong_dotcall(quoted)
      end

    arity = length(args)
    {args, maxa, guards} = toms(args, guard, __CALLER__)

    quote do
      {exactly, at_least, afterr, before, pid} =
        unquote(__MODULE__).parse_called_opts(unquote(opts))

      {pattern, guard, selection} =
        unquote(__MODULE__).called_pattern(
          unquote(module),
          unquote(function),
          unquote(arity),
          pid,
          unquote(args),
          unquote(maxa + 1),
          afterr,
          before
        )

      ms = {pattern, guard ++ unquote(guards), selection}
      unquote(__MODULE__).called_one(ms, exactly, at_least)
    end
  end

  defp toms(args, guard, env) do
    require Ex2ms

    args = Macro.expand(args, %Macro.Env{env | context: :match})
    guard = Macro.expand(guard, %Macro.Env{env | context: :guard})

    [{:{}, _, [{:{}, _, [args]}, guards, _]}] =
      quote do
        Ex2ms.fun do
          {unquote(args)} when unquote(guard) -> :ok
        end
      end
      |> Macro.expand_once(__ENV__)

    {_args, maxi} =
      args
      |> Macro.postwalk(0, fn
        atom, acc when is_atom(atom) ->
          acc =
            with(
              "$" <> s <- Atom.to_string(atom),
              {i, ""} <- Integer.parse(s)
            ) do
              max(i, acc)
            else
              _ -> acc
            end

          {atom, acc}

        other, acc ->
          {other, acc}
      end)

    {args, maxi, guards}
  end

  @doc """
  Queries a history of all calls from current or passed process.
  It is also possible to filter by module, function name, arity, args
  and timestamps.

  See `t:history_option/0` for available options.

  ## Example

      iex> Repatch.spy(Path)
      iex> Repatch.spy(MapSet)
      iex> Repatch.history()
      []
      iex> Path.rootname("file.ex")
      "file"
      iex> MapSet.new()
      MapSet.new([])
      iex> Repatch.history(module: Path, function: :rootname)
      [
        {Path, :rootname, ["file.ex"], -576460731414614326}
      ]
      iex> Repatch.history()
      [
        {Path, :rootname, ["file.ex"], -576460731414614326},
        {MapSet, :new, [], -576460731414614300},
        ...
      ]

  Works only when history is enabled in setup.
  Please make sure that module is spied on or at least patched before querying history on it.
  """
  @doc since: "1.6.0"
  @spec history([history_option()]) :: [
          {module :: module(), function :: atom(), args :: [term()],
           monotonic_timestamp :: integer()}
        ]
  def history(opts \\ []) do
    {afterr, before, pid} = parse_history_opts(opts)

    module = Keyword.get(opts, :module, :"$1")
    function = Keyword.get(opts, :function, :"$2")
    arity = Keyword.get(opts, :arity, :_)
    args = Keyword.get(opts, :args, :"$3")

    guard =
      case {afterr, before} do
        {nil, nil} ->
          []

        {afterr, nil} ->
          [{:>=, :"$4", afterr}]

        {nil, before} ->
          [{:"=<", :"$4", before}]

        {afterr, before} ->
          [{:>=, :"$4", afterr}, {:"=<", :"$4", before}]
      end

    ms =
      {{{module, function, arity, pid}, :"$4", args}, guard, [{{module, function, args, :"$4"}}]}

    :ets.select(:repatch_history, [ms])
  end

  @doc false
  def called_pattern(module, function, arity, pid, args, _index, nil, nil) do
    {{{module, function, arity, pid}, :_, args}, [], [:"$$"]}
  end

  def called_pattern(module, function, arity, pid, args, index, nil, before) do
    {{{module, function, arity, pid}, :"$#{index}", args}, [{:"=<", :"$1", before}], [:"$$"]}
  end

  def called_pattern(module, function, arity, pid, args, index, afterr, nil) do
    {{{module, function, arity, pid}, :"$#{index}", args}, [{:>=, :"$#{index}", afterr}], [:"$$"]}
  end

  def called_pattern(module, function, arity, pid, args, index, afterr, before) do
    {{{module, function, arity, pid}, :"$#{index}", args},
     [{:>=, :"$#{index}", afterr}, {:"=<", :"$#{index}", before}], [:"$$"]}
  end

  @doc false
  def called_one(key_pattern, nil, at_least) do
    called_at_least(key_pattern, at_least)
  end

  def called_one(key_pattern, exactly, _at_least) do
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

      [{_, {:recompiled, _, _}}] ->
        :ok

      [] ->
        raise CompileError,
          description: "Compilation of #{module} failed in another process"
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

  if debugging? do
    defp prepare_hook(module, function, _arity, hook) do
      fn args ->
        debug("Calling hook #{inspect(module)}.#{function}#{inspect(args)}")
        {:ok, apply(hook, args)}
      end
    end
  else
    defp prepare_hook(_module, _function, _arity, hook) do
      fn args -> {:ok, apply(hook, args)} end
    end
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
              case :erlang.get(:"$callers") do
                [_ | _] = callers ->
                  dispatch_callers(callers, module, function, arity, args)

                _ ->
                  dispatch_global(module, function, arity, args)
              end

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

  defp dispatch_callers([], module, function, arity, args) do
    dispatch_global(module, function, arity, args)
  end

  defp dispatch_callers([caller | tail], module, function, arity, args) do
    case :ets.lookup(:repatch_shared_hooks, {module, function, arity, caller}) do
      [] ->
        dispatch_callers(tail, module, function, arity, args)

      [{_, hook}] when is_function(hook) ->
        debug("Dispatched allowance with caller owner #{inspect(pid)}")
        hook.(args)
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

  defmacrop raise_not_name(x) do
    quote do
      raise ArgumentError,
            "Expected pid, valid `t:GenServer.name` or `:any`. Got #{inspect(unquote(x))}"
    end
  end

  defp resolve_pid(pid) when is_pid(pid), do: pid

  defp resolve_pid(name) when is_atom(name) do
    with :undefined <- :erlang.whereis(name) do
      raise_not_name(name)
    end
  end

  defp resolve_pid({:global, name}) do
    case :global.whereis_name(name) do
      pid when is_pid(pid) ->
        pid

      :undefined ->
        raise_not_name({:global, name})
    end
  end

  defp resolve_pid({:via, module, name} = fullname) do
    case module.whereis_name(name) do
      pid when is_pid(pid) ->
        pid

      :undefined ->
        raise_not_name(fullname)
    end
  end

  defp resolve_pid({name, local}) when is_atom(name) and local == node() do
    with :undefined <- :erlang.whereis(name) do
      raise_not_name({name, local})
    end
  end

  defp resolve_pid({name, node}) when is_atom(name) and is_atom(node) do
    with :undefined <- :erpc.call(node, :erlang, :whereis, [name]) do
      raise_not_name({name, node})
    end
  end
end
