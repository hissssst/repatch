defmodule RepatchTest do
  use ExUnit.Case, async: true

  alias Repatch.Looper
  require Repatch

  # setup do: on_exit(&Repatch.cleanup/0)

  defmacrop assert_all(results \\ [2, 2, 3, 10]) do
    [a, b, c, d] = results

    quote do
      assert X.f(1) == unquote(a)
      assert X.ff(1) == unquote(b)
      assert X.plus(1, 2) == unquote(c)
      assert X.sum([1, 2, 3, 4]) == unquote(d)
    end
  end

  test "local just works" do
    assert_all()

    Repatch.patch(X, :f, fn x -> x - 1 end)
    assert_all([0, 0, 3, 10])
  end

  test "patch fails on non-existing function" do
    assert_all()

    assert_raise ArgumentError, fn ->
      Repatch.patch(X, :does_not_exist, fn -> 1 end)
    end
  end

  test "patch fails on forbidden modules" do
    assert_raise ArgumentError, fn ->
      Repatch.patch(Keyword, :new, fn -> [] end)
    end
  end

  test "patch works on forbidden modules with option" do
    Repatch.patch(Keyword, :new, [ignore_forbidden_module: true], fn -> [] end)
  end

  test "patching patched fails" do
    Repatch.patch(X, :f, fn x -> x - 1 end)

    assert_raise ArgumentError, fn ->
      Repatch.patch(X, :f, fn x -> x - 2 end)
    end
  end

  test "patching patched works with option" do
    assert_all()
    Repatch.patch(X, :f, fn x -> x - 1 end)

    assert_all([0, 0, 3, 10])

    Repatch.patch(X, :f, [force: true], fn x -> x - 2 end)

    assert_all([-1, -1, 3, 10])
  end

  test "local with pattern matching just works" do
    assert_all()

    Repatch.patch(X, :sum, fn
      [head | tail] -> head * X.sum(tail)
      [] -> 1
    end)

    assert_all([2, 2, 3, 24])
  end

  test "local two args just works" do
    assert_all()

    Repatch.patch(X, :plus, fn xx, yy -> xx * yy end)

    assert_all([2, 2, 2, 10])
  end

  test "real just works" do
    assert_all()

    Repatch.patch(X, :f, fn x -> x - 1 end)

    assert_all([0, 0, 3, 10])

    assert Repatch.real(X.f(1)) == 2
    assert Repatch.real(X.ff(1)) == 2
  end

  test "real fails on non-calls" do
    assert_raise CompileError, fn ->
      defmodule M do
        require Repatch

        def f(x) do
          Repatch.real(x + 123)
        end
      end
    end
  end

  test "super just works" do
    assert_all()

    Repatch.patch(X, :f, fn x ->
      Repatch.super(X.f(x)) - 2
    end)

    assert_all([0, 0, 3, 10])

    assert Repatch.super(X.f(1)) == 2
    assert Repatch.super(X.ff(1)) == 0
  end

  test "super fails on non-calls" do
    assert_raise CompileError, fn ->
      defmodule M do
        require Repatch

        def f(x) do
          Repatch.super(x + 123)
        end
      end
    end
  end

  test "repatched? just works" do
    assert_all()
    refute Repatch.repatched?(X, :f, 1)

    Repatch.patch(X, :f, fn x -> x - 1 end)
    assert_all([0, 0, 3, 10])
    assert Repatch.repatched?(X, :f, 1)
  end

  test "repatched? with mode just works" do
    assert_all()
    refute Repatch.repatched?(X, :f, 1, mode: :local)
    refute Repatch.repatched?(X, :f, 1, mode: :shared)
    refute Repatch.repatched?(X, :f, 1, mode: :global)

    Repatch.patch(X, :f, fn x -> x - 1 end)
    assert Repatch.repatched?(X, :f, 1, mode: :local)
    refute Repatch.repatched?(X, :f, 1, mode: :shared)
    refute Repatch.repatched?(X, :f, 1, mode: :global)
  end

  test "cleanup test" do
    p = Looper.start_link()
    Repatch.allow(self(), p)
    assert_all()

    Repatch.patch(X, :f, fn x -> x - 1 end)
    assert_all([0, 0, 3, 10])
    assert Repatch.called?(X, :f, 1)
    assert Repatch.allowances() == [p]

    Repatch.cleanup()
    refute Repatch.called?(X, :f, 1)
    assert Repatch.allowances() == []
    assert_all()
  end
end
