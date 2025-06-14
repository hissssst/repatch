defmodule RepatchExpectationsTest do
  use ExUnit.Case, async: true
  use Repatch.ExUnit

  import Repatch.Expectations

  doctest Repatch.Expectations, import: true

  test "expect/2,3 works" do
    DateTime
    |> expect(:utc_now, [exactly: 2], fn -> :two_times end)
    |> expect(fn -> :one_time end)

    expect(DateTime, :utc_now, [at_least: :any], fn -> :any_times end)

    assert DateTime.utc_now() == :two_times
    refute expectations_empty?()

    assert DateTime.utc_now() == :two_times
    refute expectations_empty?()

    assert DateTime.utc_now() == :one_time
    assert expectations_empty?()

    assert DateTime.utc_now() == :any_times
    assert expectations_empty?()
  end

  test "expect/3 different functions" do
    expect(DateTime, :utc_now, fn -> :ok end)
    expect(Function, :identity, fn _ -> :ok end)

    assert DateTime.utc_now() == :ok
    assert Function.identity(:something) == :ok
  end

  test "expect/3 draining works" do
    expect(DateTime, :utc_now, fn -> :last end)
    assert DateTime.utc_now() == :last

    exception =
      assert_raise Repatch.Expectations.Empty, "DateTime.utc_now/0 No expectations left", fn ->
        DateTime.utc_now()
      end

    assert %{module: DateTime, function: :utc_now, arity: 0} = exception
  end

  test "expect/3 isolated from patches" do
    expect(DateTime, :utc_now, fn -> :ok end)

    s = self()

    spawn(fn ->
      Repatch.patch(DateTime, :utc_now, fn -> :from_spawned end)
      send(s, :patched)
      send(s, DateTime.utc_now())
    end)

    assert_receive :patched
    assert DateTime.utc_now() == :ok
    assert_receive :from_spawned
  end

  test "expect/3 once, any" do
    expect(DateTime, :utc_now, [exactly: :once], fn -> :one end)
    |> expect([at_least: :once], fn -> :two end)

    assert DateTime.utc_now() == :one
    assert DateTime.utc_now() == :two
    assert DateTime.utc_now() == :two

    expect(List, :last, [at_least: :any], fn _ -> :no_idea end)
    assert List.last([1, 2, 3]) == :no_idea
  end

  test "expect/3 shared works" do
    expect(DateTime, :utc_now, [mode: :shared, at_least: 1], fn -> :one end)
    owner = self()

    [p1, p2] =
      for _ <- 1..2 do
        spawn(fn ->
          receive do
            x -> send(owner, x.())
          end
        end)
      end

    Repatch.allow(self(), p1)

    send(p1, fn -> DateTime.utc_now() end)
    assert_receive :one

    send(p2, fn -> DateTime.utc_now() end)
    assert_receive %DateTime{}
  end

  test "Warns on adding after at_least" do
    io =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        DateTime
        |> expect(:utc_now, [at_least: :once], fn -> :any_times end)
        |> expect(fn -> :one_time end)
      end)

    assert io =~
             "Last expect is executed `at_least` times, therefore this one will never be executed"
  end

  test "Raises on incorrect arity in chain" do
    message = "An expectation function is of arity 1, but it is required to be 0"

    assert_raise ArgumentError, message, fn ->
      DateTime
      |> expect(:utc_now, fn -> :zero end)
      |> expect(fn _ -> :one end)
    end
  end

  test "cleanup works" do
    queue = expect(DateTime, :utc_now, fn -> :ok end)
    assert Process.alive?(Process.get(:repatch_expectations_queues))
    assert Process.alive?(queue)

    cleanup()

    refute Process.alive?(Process.get(:repatch_expectations_queues))
    refute Process.alive?(queue)
  end
end
