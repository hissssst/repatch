defmodule RepatchSharedTest do
  use ExUnit.Case, async: true

  alias Repatch.Looper

  test "shared just works" do
    p = Looper.start_link()
    assert Looper.call(p) == 4

    Repatch.patch(X, :f, [mode: :shared], fn x ->
      x + 100
    end)

    assert Looper.call(p) == 4
    assert X.f(3) == 103

    Repatch.allow(self(), p)
    assert X.f(3) == 103
    assert Looper.call(p) == 103
    assert Looper.call(p) == 103
  end

  test "double allow fails" do
    p = Looper.start_link()

    Repatch.allow(self(), p)

    assert_raise ArgumentError, fn ->
      Repatch.allow(self(), p)
    end
  end

  test "double allow with force option works" do
    p = Looper.start_link()
    p2 = Looper.start_link()

    Repatch.patch(X, :f, [mode: :shared], fn x ->
      x + 100
    end)

    Repatch.allow(self(), p)
    assert Repatch.owner(p) == self()
    assert Looper.call(p) == 103

    Repatch.allow(p2, p, force: true)
    assert Repatch.owner(p) == p2
    assert Looper.call(p) == 4
  end

  test "allow self fails" do
    assert_raise ArgumentError, fn ->
      Repatch.allow(self(), self())
    end
  end

  test "cyclic allow fails" do
    p = Looper.start_link()

    Repatch.allow(self(), p)

    assert_raise ArgumentError, fn ->
      Repatch.allow(p, self())
    end
  end

  test "shared on allowance works" do
    p = Looper.start_link()
    p2 = Looper.start_link()
    assert Looper.call(p) == 4
    assert Looper.call(p2) == 4

    Repatch.patch(X, :f, [mode: :shared], fn x ->
      x + 100
    end)

    assert Looper.call(p) == 4
    assert Looper.call(p2) == 4

    Repatch.allow(self(), p)
    Repatch.allow(p, p2)

    assert Looper.call(p) == 103
    assert Looper.call(p2) == 103
  end

  test "allowances just works" do
    [p1, p2, p3] = Enum.sort(Enum.map(1..3, fn _ -> Looper.start_link() end))

    Repatch.allow(self(), p1)
    assert Repatch.allowances() == [p1]

    Repatch.allow(self(), p2)
    assert Enum.sort(Repatch.allowances()) == [p1, p2]

    Repatch.allow(self(), p3)
    assert Enum.sort(Repatch.allowances()) == [p1, p2, p3]
  end

  test "owner just works" do
    p = Looper.start_link()
    Repatch.allow(self(), p)
    assert self() == Repatch.owner(p)
    assert nil == Repatch.owner()
  end

  test "restoring just works" do
    p = Looper.start_link()
    assert Looper.call(p) == 4

    Repatch.patch(X, :f, [mode: :shared], fn x ->
      x + 100
    end)

    assert Looper.call(p) == 4
    assert X.f(3) == 103

    Repatch.allow(self(), p)
    assert X.f(3) == 103
    assert Looper.call(p) == 103
    assert Looper.call(p) == 103

    Repatch.restore(X, :f, 1, mode: :shared)

    assert Looper.call(p) == 4
    assert X.f(3) == 4
  end

  test "chaining works" do
    p = Looper.start_link()
    p2 = Looper.start_link()
    assert X.f(3) == 4
    assert Looper.call(p) == 4
    assert Looper.call(p2) == 4

    Repatch.patch(X, :f, [mode: :shared], fn x ->
      x + 100
    end)

    assert X.f(3) == 103
    assert Looper.call(p) == 4
    assert Looper.call(p2) == 4

    Repatch.allow(self(), p)
    assert X.f(3) == 103
    assert Looper.call(p) == 103
    assert Looper.call(p2) == 4

    Repatch.allow(p, p2)
    assert X.f(3) == 103
    assert Looper.call(p) == 103
    assert Looper.call(p2) == 103
  end

  test "$callers works" do
    assert 4 == Task.await(Task.async(fn -> X.f(3) end))

    Repatch.patch(X, :f, [mode: :shared], fn x -> x * x end)
    assert 9 == Task.await(Task.async(fn -> X.f(3) end))
  end

  test "Nested $callers works" do
    assert 4 ==
             Task.await(
               Task.async(fn ->
                 Task.await(
                   Task.async(fn ->
                     X.f(3)
                   end)
                 )
               end)
             )

    Repatch.patch(X, :f, [mode: :shared], fn x -> x * x * x end)

    assert 27 ==
             Task.await(
               Task.async(fn ->
                 Task.await(
                   Task.async(fn ->
                     X.f(3)
                   end)
                 )
               end)
             )
  end
end
