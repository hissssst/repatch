defmodule Repatch1Test do
  # Tests that tests are truly isolated from each other
  use ExUnit.Case, async: true

  for i <- 1..10 do
    test "just works #{i}" do
      Repatch.patch(X, :f, fn x ->
        Process.sleep(1)
        x + unquote(i)
      end)

      assert X.f(3) == unquote(3 + i)
    end
  end
end
