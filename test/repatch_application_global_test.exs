defmodule Repatch.ApplicationGlobalTest do
  use ExUnit.Case, async: false
  use Repatch.ExUnit, isolate_env: :global

  test "Global works" do
    assert nil == Application.get_env(:ex_unit, :one)
    assert nil == Task.await(Task.async(fn -> Application.get_env(:ex_unit, :one) end))

    Application.put_env(:ex_unit, :one, :two)
    assert :two == Application.get_env(:ex_unit, :one)
    assert :two == Task.await(Task.async(fn -> Application.get_env(:ex_unit, :one) end))

    Application.delete_env(:ex_unit, :one)
    assert nil == Application.get_env(:ex_unit, :one)
    assert nil == Task.await(Task.async(fn -> Application.get_env(:ex_unit, :one) end))
  end
end
