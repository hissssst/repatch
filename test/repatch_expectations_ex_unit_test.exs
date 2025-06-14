defmodule Repatch.ExpectationsExUnitTest do
  use ExUnit.Case, async: true
  use Repatch.ExUnit, assert_expectations: true

  import Repatch.Expectations

  @moduletag skip: true

  test "fails" do
    expect(DateTime, :utc_now, fn -> :not_satisfied end)
    |> expect(fn -> :not_satisfied_too end)
    |> expect(fn -> :and_this_too end)
  end
end
