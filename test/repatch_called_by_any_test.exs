defmodule RepatchCalledByAnyTest do
  use ExUnit.Case, async: false

  alias Repatch.Looper

  test "called by any by other pid works" do
    Repatch.spy(X)
    ts = :erlang.monotonic_time()
    p = Looper.start_link()
    refute Repatch.called?(X, :f, 1, by: :any, after: ts)

    Looper.call(p)
    assert Repatch.called?(X, :f, 1, by: :any, after: ts)

    X.f(123)
    assert Repatch.called?(X, :f, 1, by: :any, after: ts)
  end

  test "called by any by other pid works 2" do
    Repatch.spy(X)
    ts = :erlang.monotonic_time()
    p = Looper.start_link()
    refute Repatch.called?(X, :f, 1, by: :any, after: ts)

    X.f(123)
    assert Repatch.called?(X, :f, 1, by: :any, after: ts)

    Looper.call(p)
    assert Repatch.called?(X, :f, 1, by: :any, after: ts)
  end
end
