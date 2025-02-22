defmodule Repatch.ApplicationTest do
  use ExUnit.Case, async: true

  doctest Repatch.Application

  setup_all do
    Application.put_env(:ex_unit, :some, :thing)
    :ok
  end

  setup tags do
    Repatch.Application.patch_application_env(tags[:opts] || [])
    owner = self()
    on_exit(fn -> Repatch.Application.cleanup(owner) end)
    :ok
  end

  test ":application.set_env/1" do
    :application.set_env([{:ex_unit, [key: :value]}])

    assert Application.get_env(:ex_unit, :key) == :value
    assert {:key, :value} in Application.get_all_env(:ex_unit)
    assert_isolation(:key, nil)
  end

  test ":application.set_env/2" do
    :application.set_env([{:ex_unit, [key: :value2]}], timeout: 1000)

    assert Application.get_env(:ex_unit, :key) == :value2
    assert {:key, :value2} in Application.get_all_env(:ex_unit)
    assert_isolation(:key, nil)
  end

  test ":application.set_env/3" do
    :application.set_env(:ex_unit, :key, :value3)

    assert Application.get_env(:ex_unit, :key) == :value3
    assert {:key, :value3} in Application.get_all_env(:ex_unit)
    assert_isolation(:key, nil)
  end

  test ":application.set_env/4" do
    :application.set_env(:ex_unit, :key, :value3, timeout: 1000)

    assert Application.get_env(:ex_unit, :key) == :value3
    assert {:key, :value3} in Application.get_all_env(:ex_unit)
    assert_isolation(:key, nil)
  end

  test ":application.unset_env/2 global" do
    :application.unset_env(:ex_unit, :some)

    assert Application.get_env(:ex_unit, :some) == nil
    assert :some not in Keyword.keys(Application.get_all_env(:ex_unit))
    assert_isolation(:some, :thing)
  end

  test ":application.unset_env/2 patched" do
    Application.put_env(:ex_unit, :some, :other_thing)
    assert Application.get_env(:ex_unit, :some) == :other_thing

    :application.unset_env(:ex_unit, :some)

    assert Application.get_env(:ex_unit, :some) == nil
    assert :some not in Keyword.keys(Application.get_all_env(:ex_unit))
    assert_isolation(:some, :thing)
  end

  test ":application.unset_env/3 patched" do
    Application.put_env(:ex_unit, :some, :other_thing)
    assert Application.get_env(:ex_unit, :some) == :other_thing

    :application.unset_env(:ex_unit, :some, timeout: 1000)

    assert Application.get_env(:ex_unit, :some) == nil
    assert :some not in Keyword.keys(Application.get_all_env(:ex_unit))
    assert_isolation(:some, :thing)
  end

  test ":application.get_env/1" do
    assert :undefined == :application.get_env(:key)
  end

  test ":application.get_env/2 global" do
    assert {:ok, :thing} == :application.get_env(:ex_unit, :some)
    assert :undefined == :application.get_env(:ex_unit, :key)
    assert_isolation(:some, :thing)
    assert_isolation(:key, nil)
  end

  test ":application.get_env/2 patched" do
    Application.put_env(:ex_unit, :some, :other_thing)
    assert {:ok, :other_thing} == :application.get_env(:ex_unit, :some)
    assert_isolation(:some, :thing)
  end

  test "Application.fetch_env/2 global" do
    assert {:ok, :thing} == Application.fetch_env(:ex_unit, :some)
    assert :error == Application.fetch_env(:ex_unit, :key)
    assert_isolation(:some, :thing)
    assert_isolation(:key, nil)
  end

  test "Application.fetch_env/2 patched" do
    Application.put_env(:ex_unit, :some, :other_thing)
    assert {:ok, :other_thing} == Application.fetch_env(:ex_unit, :some)
    assert_isolation(:some, :thing)
  end

  test "Application.fetch_env!/2 global" do
    assert :thing == Application.fetch_env!(:ex_unit, :some)
    assert_raise ArgumentError, fn -> Application.fetch_env!(:ex_unit, :key) end
    assert_isolation(:some, :thing)
    assert_isolation(:key, nil)
  end

  test "Application.fetch_env!/2 patched" do
    Application.put_env(:ex_unit, :some, :other_thing)
    assert :other_thing == Application.fetch_env!(:ex_unit, :some)
    assert_isolation(:some, :thing)
  end

  test "Application.get_env/2 global" do
    assert :thing == Application.get_env(:ex_unit, :some)
    assert :x_default == Application.get_env(:ex_unit, :key, :x_default)
    assert nil == Application.get_env(:ex_unit, :key)
    assert_isolation(:some, :thing)
    assert_isolation(:key, nil)
  end

  test "Application.get_env/2 patched" do
    Application.put_env(:ex_unit, :some, :other_thing)
    assert :other_thing == Application.get_env(:ex_unit, :some)
    assert_isolation(:some, :thing)
  end

  test ":application.get_all_env/1 global" do
    assert :thing == :application.get_all_env(:ex_unit)[:some]
    assert_isolation(:some, :thing)
  end

  test ":application.get_all_env/1 patched" do
    Application.put_env(:ex_unit, :some, :other_thing)
    assert :other_thing == :application.get_all_env(:ex_unit)[:some]
    assert_isolation(:some, :thing)
  end

  test ":application.get_all_env/0" do
    assert [] == :application.get_all_env()
  end

  test "Application.get_all_env/1 global" do
    assert :thing == Application.get_all_env(:ex_unit)[:some]
    assert_isolation(:some, :thing)
  end

  test "Application.get_all_env/1 patched" do
    Application.put_env(:ex_unit, :some, :other_thing)
    assert :other_thing == Application.get_all_env(:ex_unit)[:some]
    assert_isolation(:some, :thing)
  end

  @tag opts: [mode: :shared]
  test "Shared mode works" do
    assert :thing == Application.get_env(:ex_unit, :some)
    assert_shared(:some, :thing)
    Application.put_env(:ex_unit, :some, :other_thing)
    assert :other_thing == Application.get_env(:ex_unit, :some)
    assert_shared(:some, :other_thing)
    assert_isolation(:some, :thing)
  end

  defp assert_isolation(key, value) do
    owner = self()
    ref = make_ref()
    spawn(fn -> send(owner, {ref, Application.get_env(:ex_unit, key)}) end)

    result =
      receive do
        {^ref, result} -> result
      end

    assert result == value
  end

  defp assert_shared(key, value) do
    owner = self()
    ref = make_ref()

    spawn(fn ->
      Repatch.allow(owner, self())
      send(owner, {ref, Application.get_env(:ex_unit, key)})
    end)

    result =
      receive do
        {^ref, result} -> result
      end

    assert result == value
  end
end
