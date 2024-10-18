defmodule RepatchHistoryTest do
  use ExUnit.Case, async: true

  alias Repatch.Looper

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
end
