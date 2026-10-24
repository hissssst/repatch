defmodule RepatchOwnedHistoryTest do
  use ExUnit.Case, async: false
  use Repatch.ExUnit

  alias Repatch.Looper

  setup do
    Repatch.setup(enable_global: true, enable_history: :owned, enable_shared: true)

    on_exit(fn ->
      Repatch.setup(enable_global: true, enable_history: true, enable_shared: true)
    end)

    Repatch.spy(X)
    :ok
  end

  test "records the spying process and its tasks" do
    assert X.f(1) == 2
    task = Task.async(fn -> X.f(2) && self() end)
    task_pid = Task.await(task)

    assert Repatch.called?(X, :f, 1, exactly: :once)
    assert Repatch.called?(X, :f, [2], by: task_pid)
  end

  test "does not record a process which is not owned" do
    ts = :erlang.monotonic_time()
    p = Looper.start_link()
    assert Looper.call(p) == 4
    refute Repatch.called?(X, :f, 1, by: p)
    refute Repatch.called?(X, :f, 1, by: :any, after: ts)
  end

  test "records an allowed process" do
    p = Looper.start_link()
    Repatch.allow(self(), p)
    assert Looper.call(p) == 4
    assert Repatch.called?(X, :f, 1, by: p)
  end

  test "records every process for a global patch, until cleanup" do
    Repatch.patch(X, :plus, [mode: :global], fn x, y -> x * y end)
    p = Looper.start_link()
    assert Looper.call(p) == 4
    assert Repatch.called?(X, :f, 1, by: p)

    Repatch.restore(X, :plus, 2, mode: :global)
    Repatch.cleanup()
    assert Looper.call(p) == 4
    refute Repatch.called?(X, :f, 1, by: p)
  end

  test "does not record calls of a module nobody spied on or patched" do
    Repatch.cleanup()
    assert X.f(1) == 2
    refute Repatch.called?(X, :f, 1)
  end

  test "cleanup removes calls made for the process and stops recording them" do
    owner = self()
    task_pid = Task.async(fn -> X.f(2) && self() end) |> Task.await()
    assert Repatch.called?(X, :f, 1, by: task_pid)

    Task.async(fn -> Repatch.cleanup(owner) end) |> Task.await()

    refute Repatch.called?(X, :f, 1, by: task_pid)
    assert X.f(1) == 2
    refute Repatch.called?(X, :f, 1)
  end
end

defmodule RepatchHistoryCleanupTest do
  use ExUnit.Case, async: true

  test "cleanup removes the calls of the process' tasks too" do
    Repatch.spy(X)
    owner = self()
    task_pid = Task.async(fn -> X.f(2) && self() end) |> Task.await()
    assert Repatch.called?(X, :f, 1, by: task_pid)

    Task.async(fn -> Repatch.cleanup(owner) end) |> Task.await()

    refute Repatch.called?(X, :f, 1, by: task_pid)
  end
end

defmodule RepatchHistoryRootCallerTest do
  use ExUnit.Case, async: true

  test "cleanup removes the calls of the process' tasks even when it spied on nothing" do
    Repatch.recompile(X)
    owner = self()
    task_pid = Task.async(fn -> X.f(2) && self() end) |> Task.await()
    assert Repatch.called?(X, :f, 1, by: task_pid)

    Task.async(fn -> Repatch.cleanup(owner) end) |> Task.await()

    refute Repatch.called?(X, :f, 1, by: task_pid)
  end
end
