defmodule RepatchSetupTest do
  use ExUnit.Case, async: false

  alias Repatch.Looper

  @moduletag skip: true

  setup do
    Repatch.restore_all()

    on_exit(fn ->
      Repatch.restore_all()

      Repatch.setup(
        enable_global: true,
        enable_history: true,
        enable_shared: true
      )
    end)
  end

  test "Disabled history works" do
    Repatch.setup(
      enable_global: true,
      enable_history: false,
      enable_shared: true
    )

    Repatch.patch(X, :f, fn x -> x - 2 end)

    assert X.f(1) == -1

    assert_raise ArgumentError, fn ->
      Repatch.called?(X, :f, 1)
    end
  end

  test "Disabled shared hooks works" do
    Repatch.setup(
      enable_global: true,
      enable_history: false,
      enable_shared: false
    )

    p = Looper.start_link()

    assert_raise ArgumentError, fn ->
      Repatch.patch(X, :f, [mode: :shared], fn x -> x - 2 end)
    end

    assert_raise ArgumentError, fn ->
      Repatch.allow(self(), p)
    end

    Repatch.patch(X, :f, [mode: :global], fn x -> x - 2 end)

    assert X.f(1) == -1

    assert_raise ArgumentError, fn ->
      Repatch.restore(X, :f, 1, mode: :shared)
    end
  end

  test "Disabled global hooks works" do
    Repatch.setup(
      enable_global: false,
      enable_history: false,
      enable_shared: false
    )

    assert_raise ArgumentError, fn ->
      Repatch.patch(X, :f, [mode: :global], fn x -> x - 2 end)
    end

    Repatch.patch(X, :f, fn x -> x + 19 end)

    assert X.f(1) == 20

    assert_raise ArgumentError, fn ->
      Repatch.restore(X, :f, 1, mode: :global)
    end
  end
end
