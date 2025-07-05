defmodule RepatchTest do
  use ExUnit.Case, async: true

  require X
  require Repatch

  doctest Repatch,
    except: [
      notify: 1,
      notify: 2,
      notify: 3,
      notify: 4,
      setup: 1,
      setup: 0,
      restore_all: 0,
      history: 0,
      history: 1
    ]

  alias Repatch.Looper

  Code.put_compiler_option(:no_warn_undefined, [{X, :private, 1}])

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
    Repatch.patch(Agent, :stop, [ignore_forbidden_module: true], fn _agent -> [] end)
  end

  test "patching generated fails" do
    assert_raise ArgumentError, fn ->
      Repatch.patch(X, :__f_repatch, fn x -> x - 1 end)
    end
  end

  test "patching patched fails" do
    Repatch.patch(X, :f, fn x -> x - 1 end)

    assert_raise ArgumentError, "Function X.f/1 is already patched", fn ->
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

  test "restoring local just works" do
    assert_all()

    Repatch.patch(X, :f, fn x -> x - 1 end)
    assert_all([0, 0, 3, 10])

    Repatch.restore(X, :f, 1)
    assert_all()
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

  test "real fails on repatch-generated" do
    assert_raise CompileError, fn ->
      defmodule M do
        require Repatch

        def f(x) do
          Repatch.real(X."REPATCH-f"(1))
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

  test "super fails on repatch-generated" do
    assert_raise CompileError, fn ->
      defmodule M do
        require Repatch

        def f(x) do
          Repatch.super(X."REPATCH-f"(1))
        end
      end
    end
  end

  test "private just works" do
    assert X.public(1) == 3

    assert_raise UndefinedFunctionError, fn ->
      apply(X, :private, [1])
    end

    Repatch.patch(X, :private, fn x -> x - 1 end)

    assert X.public(1) == 1
    assert Repatch.private(X.private(1)) == 0
  end

  test "private fails on non-calls works" do
    assert_raise CompileError, fn ->
      defmodule M do
        require Repatch

        def f(x) do
          Repatch.private(x + 123)
        end
      end
    end
  end

  test "private fails on repatch-generated" do
    assert_raise CompileError, fn ->
      defmodule M do
        require Repatch

        def f(x) do
          Repatch.private(X."REPATCH-f"(1))
        end
      end
    end
  end

  test "super in private works" do
    assert X.public(1) == 3

    assert_raise UndefinedFunctionError, fn ->
      apply(X, :private, [1])
    end

    Repatch.patch(X, :private, fn x -> Repatch.super(X.private(x)) - 2 end)

    assert X.public(1) == 1
    assert Repatch.private(X.private(1)) == 0
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

  test "patching macro works" do
    assert X.macro(123) == 1230

    Repatch.patch(X, :macro, fn _caller, x -> quote do: unquote(x) / 10 end)

    defmodule YYY do
      require X

      def f(x) do
        X.macro(x)
      end
    end

    assert YYY.f(123) == 12.3
  end

  test "sticky module test" do
    assert :code.is_sticky(:string)
    assert :string.is_empty("")

    Repatch.patch(:string, :is_empty, fn _ -> "Not even boolean" end)

    assert :code.is_sticky(:string)
    assert :string.is_empty("") == "Not even boolean"
  end

  test "info test" do
    Repatch.patch(X, :f, fn x -> x - 1 end)

    assert [:patched, :local] == Repatch.info(X, :f, 1, self())
    caller = self()
    assert %{^caller => [:patched, :local]} = Repatch.info(X, :f, 1, :any)
  end

  test "multi-clause function test" do
    Repatch.patch(X, :claused, fn x -> x + 100 end)

    assert X.claused(100) == 200
    assert X.claused(1000) == 1100
    assert X.claused(1) == 101
    assert X.claused(2) == 102
  end

  test "private test" do
    assert_raise UndefinedFunctionError, fn ->
      X.private(1)
    end

    Repatch.patch(X, :private, fn x ->
      x + 1234
    end)

    assert Repatch.private(X.private(4321)) == 5555

    assert_raise UndefinedFunctionError, fn ->
      Repatch.private(X.public(4321))
    end
  end
end
