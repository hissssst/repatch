defmodule RepatchHistoryTest do
  use ExUnit.Case, async: true

  alias Repatch.Looper
  require Repatch

  test "called with arity" do
    Repatch.spy(X)

    refute Repatch.called?(X, :f, 1, exactly: :once)
    refute Repatch.called?(X, :f, 1)

    assert X.f(123) == 124
    assert Repatch.called?(X, :f, 1, exactly: :once)

    assert X.f(123) == 124
    refute Repatch.called?(X, :f, 1, exactly: :once)
    assert Repatch.called?(X, :f, 1, at_least: :once)
    assert Repatch.called?(X, :f, 1, exactly: 2)
  end

  test "called fails when exactly < at_least" do
    Repatch.spy(X)

    assert_raise ArgumentError, fn ->
      Repatch.called?(X, :f, 1, exactly: :once, at_least: 2)
    end

    assert_raise ArgumentError, fn ->
      Repatch.called?(X, :f, 1, exactly: 0)
    end

    assert_raise ArgumentError, fn ->
      Repatch.called?(X, :f, 1, exactly: 10, at_least: 12)
    end
  end

  test "called fails when at_least: nil" do
    Repatch.spy(X)

    assert_raise ArgumentError, fn ->
      Repatch.called?(X, :f, 1, at_least: nil)
    end

    refute Repatch.called?(X, :f, 1, at_least: nil, exactly: :once)
  end

  test "called with args" do
    Repatch.spy(X)

    assert X.f(123) == 124
    assert Repatch.called?(X, :f, [123], exactly: :once)
    refute Repatch.called?(X, :f, [-100_500])

    assert X.f(123) == 124
    refute Repatch.called?(X, :f, [123], exactly: :once)
    assert Repatch.called?(X, :f, [123], at_least: :once)
    assert Repatch.called?(X, :f, [123], exactly: 2)
    refute Repatch.called?(X, :f, [-100_500])
  end

  test "called after/before" do
    Repatch.spy(X)
    refute Repatch.called?(X, :f, 1)

    assert X.f(123) == 124

    ts = :erlang.monotonic_time()
    refute Repatch.called?(X, :f, 1, after: ts)
    assert Repatch.called?(X, :f, 1, before: ts)

    assert X.f(123) == 124
    assert Repatch.called?(X, :f, 1, after: ts)
    assert Repatch.called?(X, :f, 1, before: ts)
  end

  test "called after and before" do
    Repatch.spy(X)
    refute Repatch.called?(X, :f, 1)
    ts0 = :erlang.monotonic_time()

    assert X.f(123) == 124

    ts1 = :erlang.monotonic_time()
    ts2 = :erlang.monotonic_time()

    assert X.f(123) == 124

    ts3 = :erlang.monotonic_time()

    assert Repatch.called?(X, :f, 1, after: ts0, before: ts1)
    refute Repatch.called?(X, :f, 1, after: ts1, before: ts2)
    assert Repatch.called?(X, :f, 1, after: ts2, before: ts3)
  end

  test "fails when after < before" do
    Repatch.spy(X)
    ts0 = :erlang.monotonic_time()
    Process.sleep(10)
    ts1 = :erlang.monotonic_time()

    assert_raise ArgumentError, fn ->
      Repatch.called?(X, :f, 1, after: ts1, before: ts0)
    end
  end

  test "called by pid" do
    Repatch.spy(X)
    p = Looper.start_link()
    refute Repatch.called?(X, :f, 1, by: p)

    assert Looper.call(p) == 4
    assert Repatch.called?(X, :f, 1, by: p)
    assert Repatch.called?(X, :f, [3], by: p)

    assert Looper.call(p) == 4
    refute Repatch.called?(X, :f, 1, by: p, exactly: :once)
    assert Repatch.called?(X, :f, 1, by: p, at_least: :once)
    assert Repatch.called?(X, :f, 1, by: p, exactly: 2)
  end

  test "called by argument error" do
    Repatch.spy(X)

    assert_raise ArgumentError, fn -> Repatch.called?(X, :f, 1, by: :definitely_not_supported) end
  end

  test "called macro" do
    require Repatch

    Repatch.spy(X)
    onetwothree = 123

    assert X.f(123) == 124
    assert Repatch.called?(X.f(123))
    assert Repatch.called?(X.f(^onetwothree))
    assert Repatch.called?(X.f(_))
    assert Repatch.called?(X.f(x) when x == 123)
    assert Repatch.called?(X.f(x) when x >= 0)

    refute Repatch.called?(X.f(x) when x < 123)
    refute Repatch.called?(X.f(124))
  end

  test "history" do
    Repatch.spy(X)

    assert X.f(123) == 124
    assert X.f(123) == 124
    assert X.f(123) == 124

    assert [
             {X, :f, [123], _},
             {X, :f, [123], _},
             {X, :f, [123], _}
           ] = Repatch.history()

    assert [
             {X, :f, [123], _},
             {X, :f, [123], _},
             {X, :f, [123], _}
           ] = Repatch.history(module: X)

    assert [
             {X, :f, [123], _},
             {X, :f, [123], _},
             {X, :f, [123], _}
           ] = Repatch.history(function: :f)

    assert X.f(1) == 2

    assert [{X, :f, [1], _}] = Repatch.history(args: [1])
  end

  test "notify/4 shared just works" do
    executor =
      spawn_link(fn ->
        receive do
          :go -> DateTime.utc_now()
        end
      end)

    Repatch.allow(self(), executor)

    notification = Repatch.notify(DateTime, :utc_now, 0, mode: :shared)

    send(executor, :go)

    assert_receive ^notification
  end

  test "notify/2 shared just works" do
    executor =
      spawn_link(fn ->
        receive do
          :go -> DateTime.utc_now()
        end
      end)

    Repatch.allow(self(), executor)

    notification = Repatch.notify(DateTime.utc_now(), mode: :shared)

    send(executor, :go)

    assert_receive ^notification
  end

  test "notify/4 local just works" do
    notification = Repatch.notify(DateTime, :utc_now, 0)
    refute_receive ^notification

    assert %DateTime{} = DateTime.utc_now()
    assert_receive ^notification
  end

  test "notify/2 local just works" do
    notification = Repatch.notify(DateTime.utc_now())
    refute_receive ^notification

    assert %DateTime{} = DateTime.utc_now()
    assert_receive ^notification
  end
end
