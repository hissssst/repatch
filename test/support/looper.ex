defmodule Repatch.Looper do
  def start_link do
    spawn_link(&loop/0)
  end

  def call(pid, module \\ X, function \\ :f, args \\ [3]) do
    ref = make_ref()
    send(pid, {:check, ref, self(), module, function, args})

    receive do
      {^ref, result} ->
        result
    after
      100 ->
        false
    end
  end

  defp loop do
    receive do
      {:check, ref, to, module, function, args} ->
        send(to, {ref, apply(module, function, args)})
        loop()
    end
  end
end
