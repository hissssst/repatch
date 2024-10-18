defmodule RepatchGlobalTest do
  use ExUnit.Case, async: false
  use Repatch.ExUnit

  alias Repatch.Looper

  test "global works" do
    p = Looper.start_link()

    assert X.f(1) == 2
    assert X.ff(1) == 2
    assert X.plus(1, 2) == 3
    assert X.sum([1, 2, 3, 4]) == 10

    Repatch.patch(X, :f, [mode: :global], fn x ->
      x - 1
    end)

    assert X.f(1) == 0
    assert X.ff(1) == 0
    assert X.plus(1, 2) == 3
    assert X.sum([1, 2, 3, 4]) == 10

    assert Looper.call(p, X, :f, [1]) == 0
    assert Looper.call(p, X, :ff, [1]) == 0
    assert Looper.call(p, X, :plus, [1, 2]) == 3
    assert Looper.call(p, X, :sum, [[1, 2, 3, 4]]) == 10
  end

  test "restore global works" do
    p = Looper.start_link()
    assert X.f(1) == 2
    assert Looper.call(p, X, :f, [1]) == 2

    Repatch.patch(X, :f, [mode: :global], fn x ->
      x - 1
    end)

    assert X.f(1) == 0
    assert Looper.call(p, X, :f, [1]) == 0

    Repatch.restore(X, :f, 1, mode: :global)

    assert X.f(1) == 2
    assert Looper.call(p, X, :f, [1]) == 2
  end
end
