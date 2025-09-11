defmodule Repatch.SystemTest do
  use ExUnit.Case, async: false
  use Repatch.ExUnit

  setup do
    on_exit(&Repatch.restore_all/0)
    :ok
  end

  test "System.fetch_env patching works" do
    Repatch.patch(System, :fetch_env, fn _key -> "Patched" end)

    assert System.fetch_env("X") == "Patched"
    assert System.fetch_env("Y") == "Patched"
  end
end
