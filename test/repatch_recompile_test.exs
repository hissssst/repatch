defmodule RepatchRecompileTest do
  use ExUnit.Case, async: false

  alias RecompileSubject, as: Subject

  @moduletag skip: true

  setup do
    Repatch.restore_all()
    on_exit(fn -> Repatch.restore_all() end)
  end

  describe "recompile_only" do
    test "works" do
      opts = [recompile_only: [{Subject, :f, 1}]]
      assert Subject.f(1) == 2
      Repatch.patch(Subject, :f, opts, fn x -> x end)
      assert Subject.f(1) == 1
      assert Subject.g(2) == 4

      refute Repatch.called?(Subject, :g, 1)
    end

    test "fails on non-mfarity" do
      opts = [recompile_only: [{Subject, :xx, nil}]]

      assert_raise ArgumentError, fn ->
        Repatch.patch(Subject, :f, opts, fn x -> x end)
      end
    end
  end

  describe "recompile_except" do
    test "works" do
      opts = [recompile_except: [{Subject, :g, 1}]]
      assert Subject.f(1) == 2
      Repatch.patch(Subject, :f, opts, fn x -> x end)
      assert Subject.f(1) == 1
      assert Subject.g(2) == 4

      refute Repatch.called?(Subject, :g, 1)
    end

    test "fails on non-mfarity" do
      opts = [recompile_except: [{Subject, :xx, nil}]]

      assert_raise ArgumentError, fn ->
        Repatch.patch(Subject, :f, opts, fn x -> x end)
      end
    end

    test "fails on intersection" do
      opts = [recompile_except: [{Subject, :f, 1}], recompile_only: [{Subject, :f, 1}]]

      assert_raise ArgumentError, fn ->
        Repatch.patch(Subject, :f, opts, fn x -> x end)
      end
    end
  end

  describe "recompile option" do
    test "recompile" do
      Repatch.setup(recompile: [Subject], enable_history: true)
      assert Subject.f(1) == 2
      # , exactly: :once)
      assert Repatch.called?(Subject, :f, 1)
    end
  end

  test "no binary" do
    defmodule NoBinary do
      def f(x) do
        x + 1
      end
    end

    assert_raise ArgumentError, "Binary for module #{inspect(NoBinary)} is unavailable", fn ->
      Repatch.patch(NoBinary, :f, fn x -> x end)
    end
  end

  test "no module" do
    m = ThisModuleDoesNotExistRepatch

    assert_raise ArgumentError, "Module #{inspect(m)} does not exist", fn ->
      Repatch.patch(m, :f, fn x -> x end)
    end
  end
end
