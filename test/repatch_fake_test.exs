defmodule RepatchFakeTest do
  use ExUnit.Case, async: true
  require Repatch

  defmodule Y do
    def f(x) do
      x - 1
    end
  end

  test "fake and real works" do
    assert X.f(1) == 2

    assert_raise UndefinedFunctionError, fn ->
      apply(X, :g, [1])
    end

    Repatch.fake(X, Y)

    assert X.f(1) == 0

    assert_raise UndefinedFunctionError, fn ->
      apply(X, :g, [1])
    end

    assert Repatch.real(X.f(1)) == 2
  end

  test "fails on the same module" do
    assert_raise ArgumentError, fn ->
      Repatch.fake(X, X)
    end
  end
end
