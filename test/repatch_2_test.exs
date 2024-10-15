defmodule Repatch2Test do
  # Tests what tests are truly isolated from each other
  use ExUnit.Case, async: true

  for i <- 100..110 do
    test "just works #{i}" do
      Repatch.patch(X, :f, fn x ->
        Process.sleep(1)
        x + unquote(i)
      end)

      assert X.f(3) == unquote(3 + i)
    end
  end
end
