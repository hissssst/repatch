defmodule RepatchRestoreAllTest do
  use ExUnit.Case, async: false

  test "restore_all just works" do
    assert X.f(1) == 2
    assert Repatch.called?(X, :f, 1, exactly: :once)

    Repatch.patch(X, :f, fn x -> x - 1 end)

    assert X.f(1) == 0
    assert Repatch.called?(X, :f, 1, exactly: 2)

    Repatch.restore_all()
    assert X.f(1) == 2
    refute Repatch.called?(X, :f, 1, at_least: :once)
  end
end
