defmodule RepatchSetupTest do
  use ExUnit.Case, async: false

  setup do
    Repatch.restore_all()

    on_exit(fn ->
      Repatch.setup(
        enable_global: true,
        enable_history: true,
        enable_shared: true
      )
    end)
  end
end
