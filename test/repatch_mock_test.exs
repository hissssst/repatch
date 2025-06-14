defmodule Repatch.MockTest do
  use ExUnit.Case, async: true

  alias Repatch.Mock

  @compile {:no_warn_undefined, Something}
  @compile {:no_warn_undefined, SomeModule}

  doctest Mock, import: true

  defmodule Beh do
    @callback f(any(), any()) :: any()

    @callback g(any(), any()) :: any()

    @optional_callbacks [g: 2]
  end

  defprotocol Prot do
    def f(x, y)
  end

  def unique_name do
    :"Elixir.TestModule#{:erlang.unique_integer([:positive])}"
  end

  test "Patching mocked function works" do
    module = unique_name()
    Mock.define(module, behaviour: Beh)

    assert_raise Repatch.Mock.NotImplemented, fn ->
      module.f(1, 2)
    end

    Repatch.patch(module, :f, fn l, r -> l + r end)

    assert module.f(1, 2) == 3
  end

  test "Protocols with reconsolidation work" do
    Code.put_compiler_option(:ignore_already_consolidated, false)
    module = unique_name()
    Mock.define(module, protocol: Enumerable, reconsolidate: true)
    structure = struct(module, [])

    assert_raise Repatch.Mock.NotImplemented, fn ->
      Enumerable.count(structure)
    end

    Repatch.patch(Module.concat(Enumerable, module), :count, fn _ -> 0 end)

    assert Enumerable.count(structure) == 0
    refute Code.get_compiler_option(:ignore_already_consolidated)
  end

  test "Protocols without reconsolidation work" do
    module = unique_name()
    Mock.define(module, protocol: Prot)
    structure = struct(module, [])

    assert_raise Repatch.Mock.NotImplemented, fn ->
      Prot.f(structure, 1)
    end

    Repatch.patch(Module.concat(Prot, module), :f, fn _, y -> y end)

    assert Prot.f(structure, 10) == 10
  end

  test "except: :optional works" do
    module = unique_name()
    Mock.define(module, behaviour: Beh, except: :optional)

    assert_raise UndefinedFunctionError, fn ->
      module.g(1, 2)
    end
  end

  test "except: list works" do
    module = unique_name()
    Mock.define(module, behaviour: Beh, except: [f: 2])

    assert_raise UndefinedFunctionError, fn ->
      module.f(1, 2)
    end

    assert_raise Repatch.Mock.NotImplemented, fn ->
      module.g(1, 2)
    end
  end

  test "only: list works" do
    module = unique_name()
    Mock.define(module, behaviour: Beh, only: [g: 2])

    assert_raise UndefinedFunctionError, fn ->
      module.f(1, 2)
    end

    assert_raise Repatch.Mock.NotImplemented, fn ->
      module.g(1, 2)
    end
  end

  test "defstruct_fields works" do
    module = unique_name()
    Mock.define(module, defstruct_fields: [:x, y: 1], protocol: Prot)

    assert %{x: 10, y: 1} = struct(module, x: 10)
  end
end
