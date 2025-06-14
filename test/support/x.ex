defmodule X do
  def f(x) do
    x + 1
  end

  def plus(x, y) when is_integer(x) and is_integer(y) do
    x + y
  end

  def sum([head | tail]) do
    head + sum(tail)
  end

  def sum([]), do: 0

  def ff(x) do
    f(x)
  end

  defp private(x) do
    x + 1
  end

  def public(x) do
    private(x) + 1
  end

  defmacro macro(x) do
    quote do: unquote(x) * 10
  end

  def claused(1) do
    2
  end

  def claused(2) do
    4
  end

  def claused(_other) do
    1024
  end
end
