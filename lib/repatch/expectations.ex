defmodule Repatch.Expectations do
  @moduledoc """
  Helpers for working with repatch in an imperative mocking style.
  See `expect/4` for more documentation.

  ## Example

      defmodule SuperComputerTest do
        use ExUnit.Case, async: true
        use Repatch.ExUnit, assert_expectations: true

        import Repatch.Expectations

        test "SuperComputer.meaning_of/1" do
          expect(SuperComputer, :meaning_of, fn :life -> 42 end)
          |> expect(fn 42 -> :life end)

          assert SuperComputer.meaning_of(:life) == 42
          assert SuperComputer.meaning_of(42) == :life
        end
      end
  """

  defmodule Empty do
    @moduledoc "This exception is raised when function is called without any expectations left in queue"
    defexception [:message, :module, :function, :arity]

    def message(%{message: message, module: module, function: function, arity: arity}) do
      "#{inspect(module)}.#{function}/#{arity} #{message}"
    end
  end

  defmodule Queues do
    @moduledoc false

    def all(pid \\ Process.get(:repatch_expectations_queues))

    def all(pid) when is_pid(pid) do
      Agent.get(pid, &Function.identity/1)
    end

    def all(nil) do
      %{}
    end

    def get(pid \\ Process.get(:repatch_expectations_queues), key)

    def get(pid, key) when is_pid(pid) do
      Agent.get(pid, &Map.get(&1, key))
    end

    def get(nil, _) do
      nil
    end

    def put(pid \\ Process.get(:repatch_expectations_queues), key, value)

    def put(pid, key, queue) when is_pid(pid) do
      Agent.update(pid, fn queues ->
        Process.link(queue)
        Map.put(queues, key, queue)
      end)
    end

    def put(nil, key, queue) do
      {:ok, pid} =
        Agent.start(fn ->
          Process.link(queue)
          %{key => queue}
        end)

      Process.put(:repatch_expectations_queues, pid)
      :ok
    end

    def init() do
      {:ok, pid} = Agent.start(fn -> %{} end)
      Process.put(:repatch_expectations_queues, pid)
      pid
    end
  end

  @typedoc """
  Options passed in the `expect/4` function.

  * `exactly` (positive integer or `once`) — If the function is expected to be called this exact amount of times. Defaults to `1`.
  * `at_least` (non negative integer or `once` or `any`) — If the function is expected to be called at least this amount of times.
  This option works similar to stubs in Mox library.
  * `ignore_forbidden_module` (boolean) — Whether to ignore the warning about forbidden module is being spied. Defaults to `false`.
  * `force` (boolean) — Whether to override previously set patches to function. Defaults to `false`.
  * `mode` (`:local` | `:shared` | `:global`) — What mode to use for the patch. See `t:Repatch.mode/0` for more info. Defaults to `:local`.
  * `expectations_queue` (`t:queue/0`) — The queue of expectations. It is optional

  When no `exacly` or `at_least` options are specified, the default behaviour is `exactly: 1`
  """
  @type expect_option :: {:times, pos_integer()} | Repatch.patch_option()

  @opaque queue :: pid()

  @opaque queues :: pid

  @type key :: {module(), atom(), arity()}

  @type expectation ::
          {:exactly, pos_integer(), (... -> any())}
          | {:at_least, non_neg_integer(), (... -> any())}

  @doc """
  Queues up the patch which will be executed once (or multiple times) and then removed from queue.
  Once all patches are executed, calls to patched function will fail.

  See `t:expect_option/0` for all available options.

  ## Example

      iex> expect(DateTime, :utc_now, fn -> :first end)
      iex> |> expect(fn -> :second end)
      iex> |> expect(fn -> :third end)
      iex> [DateTime.utc_now(), DateTime.utc_now(), DateTime.utc_now()]
      [:first, :second, :third]

  ## Notes

  * `expect/4` supports isolation modes just like `Repatch.patch/4` does.

  * When function called without any expectations empty, it will raise `Repatch.Expectations.Empty`.

  * Calling `Repatch.patch/4` with `force: true` will override all `expect/2` calls in the current isolation.

  * To validate the `exactly` and `at_least` options, you can use the
  `expectations_empty?/0` function or use `Repatch.ExUnit` with `assert_expectations` option.
  """
  @spec expect(module(), atom(), [expect_option()], (... -> any())) :: queue()
  def expect(module, name, opts, func) do
    queue =
      Keyword.get_lazy(opts, :expectations_queue, fn ->
        arity = arity(func)
        key = {module, name, arity}

        with nil <- Queues.get(key) do
          queue = start_queue(module, name, arity, opts)
          Queues.put(key, queue)
          queue
        end
      end)

    expect(queue, opts, func)
  end

  @doc "See `expect/4`"
  @spec expect(module(), atom(), (... -> any())) :: queue()
  def expect(module, name, func) when is_atom(module) do
    expect(module, name, [], func)
  end

  @spec expect(queue(), [expect_option()], (... -> any())) :: queue()
  def expect(queue, opts, func) when is_pid(queue) do
    {{tag, times}, opts} = pop_times(opts)
    ignore_last_at_least_warning = Keyword.get(opts, :ignore_last_at_least_warning, false)

    result =
      Agent.get_and_update(queue, fn queue ->
        push_queue(queue, tag, times, func)
      end)

    case result do
      :ok ->
        queue

      {:error, :last_is_at_least} ->
        unless ignore_last_at_least_warning do
          IO.warn(
            "Last expect is executed `at_least` times, therefore this one will never be executed"
          )
        end

        queue

      {:error, {:wrong_arity, arity}} ->
        raise ArgumentError,
              "An expectation function is of arity #{arity(func)}, but it is required to be #{arity}"
    end
  end

  @doc "See `expect/4`"
  @spec expect(queue(), (... -> any())) :: queue()
  def expect(queue, func) when is_pid(queue) do
    expect(queue, [], func)
  end

  @doc """
  Lists all not-yet executed expectations

  ## Example

      iex> func = fn -> :hello end
      iex> expect(DateTime, :utc_now, func)
      iex> pending_expectations()
      [{{DateTime, :utc_now, 0}, [{:exactly, 1, func}]}]
      iex> DateTime.utc_now()
      iex> pending_expectations()
      []

  Please note that `at_least` expectations are always returned by the `pending_expectations/0`
  """
  @spec pending_expectations(queues()) :: [{key, [expectation()]}]
  def pending_expectations(queues \\ Queues.all()) do
    Enum.flat_map(queues, fn {key, queue} ->
      case Agent.get(queue, fn queue -> queue end) do
        {[], []} ->
          []

        queue ->
          expectations = :queue.to_list(queue)
          [{key, expectations}]
      end
    end)
  end

  @doc """
  Checks if there are any expectations empty. Useful in asserts

  ## Example

      iex> expect(DateTime, :utc_now, [at_least: 1], fn -> 123 end)
      iex> expectations_empty?()
      false
      iex> DateTime.utc_now()
      iex> expectations_empty?()
      true
  """
  @spec expectations_empty?(queues()) :: boolean()
  def expectations_empty?(queues \\ Queues.all()) do
    queues
    |> pending_expectations()
    |> Enum.all?(&match?({_key, [{:at_least, 0, _}]}, &1))
  end

  @doc """
  Performs cleanup of expectations queues. Returns `true` if
  queues were found and cleaned up. Returns `false` if no expectations
  queues were found

  ## Example

      iex> expect(DateTime, :utc_now, fn -> :ok end)
      iex> cleanup()
      true
  """
  @spec cleanup(queues()) :: boolean()
  def cleanup(queues \\ Process.get(:repatch_expectations_queues))

  def cleanup(nil) do
    false
  end

  def cleanup(queues) when is_pid(queues) do
    Process.exit(queues, :cleanup)
    true
  end

  defp start_queue(module, name, arity, opts) do
    {:ok, queue} = Agent.start(fn -> :queue.new() end)

    Repatch.recompile(module, opts)

    Repatch.add_hook(
      module,
      name,
      arity,
      fn args ->
        case Agent.get_and_update(queue, &pop_queue/1) do
          func when is_function(func) ->
            {:ok, apply(func, args)}

          nil ->
            raise Empty,
              module: module,
              function: name,
              arity: arity,
              message: "No expectations left"
        end
      end,
      opts
    )

    queue
  end

  defp push_queue(queue, tag, times, func) do
    with(
      false <- :queue.is_empty(queue),
      {:at_least, _, _last} <- :queue.get_r(queue)
    ) do
      {{:error, :last_is_at_least}, queue}
    else
      {_, _, last} ->
        arity = arity(func)

        case arity(last) do
          ^arity ->
            queue = :queue.in({tag, times, func}, queue)
            {:ok, queue}

          other ->
            {{:error, {:wrong_arity, other}}, queue}
        end

      true ->
        queue = :queue.in({tag, times, func}, queue)
        {:ok, queue}
    end
  end

  defp pop_queue(queue) do
    case :queue.out(queue) do
      {{:value, {:exactly, 1, func}}, queue} ->
        {func, queue}

      {{:value, {tag, times, func}}, queue} when is_integer(times) and times >= 1 ->
        queue = :queue.in_r({tag, times - 1, func}, queue)
        {func, queue}

      {{:value, {:at_least, 0, func}}, queue} ->
        queue = :queue.in_r({:at_least, 0, func}, queue)
        {func, queue}

      {:empty, queue} ->
        {nil, queue}
    end
  end

  defp pop_times(opts) do
    {at_least, opts} = Keyword.pop(opts, :at_least)
    {exactly, opts} = Keyword.pop(opts, :exactly)

    times =
      case {at_least, exactly} do
        {nil, nil} ->
          {:exactly, 1}

        {:once, nil} ->
          {:at_least, 1}

        {:any, nil} ->
          {:at_least, 0}

        {nil, :once} ->
          {:exactly, 1}

        {at_least, _} when is_integer(at_least) and at_least >= 0 ->
          {:at_least, at_least}

        {nil, exactly} when is_integer(exactly) and exactly >= 1 ->
          {:exactly, exactly}
      end

    {times, opts}
  end

  defp arity(func) do
    func
    |> :erlang.fun_info()
    |> Keyword.fetch!(:arity)
  end
end
