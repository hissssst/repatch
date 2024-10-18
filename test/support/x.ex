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
end
