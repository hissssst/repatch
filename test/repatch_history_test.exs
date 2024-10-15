defmodule RepatchHistoryTest do
  use ExUnit.Case, async: true

  alias Repatch.Looper

  test "called with arity" do
    Repatch.spy(X)

    assert X.f(123) == 124
    assert Repatch.called?(X, :f, 1, exactly: :once)

    assert X.f(123) == 124
    refute Repatch.called?(X, :f, 1, exactly: :once)
    assert Repatch.called?(X, :f, 1, at_least: :once)
    assert Repatch.called?(X, :f, 1, exactly: 2)
  end

  test "called with args" do
    Repatch.spy(X)

    assert X.f(123) == 124
    assert Repatch.called?(X, :f, [123], exactly: :once)

    assert X.f(123) == 124
    refute Repatch.called?(X, :f, [123], exactly: :once)
    assert Repatch.called?(X, :f, [123], at_least: :once)
    assert Repatch.called?(X, :f, [123], exactly: 2)
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
end
