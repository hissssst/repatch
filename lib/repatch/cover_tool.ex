defmodule Repatch.CoverTool do
  @moduledoc """
  Add this cover tool to your mix project like this.

  ```elixir
  defmodule MyApp.MixProject do
    use Mix.Project

    def project do
      [
        test_coverage: [tool: Repatch.CoverTool, tool: <other_tool_if_any>]
      ]
    end
  end
  ```

  It will fix coverage for modules patched by Repatch. When patched function is called,
  it will be counted as covered only if original implementation is called, not the patched one.

  > ### Support {: .info}
  >
  > As of #{Mix.Project.config()[:version]}, Repatch coverage was tested only for systems with native coverage (you're using one most likely).
  > Systems with no support for native coverage may work, the code is there, but it was never actually tested.
  """

  @doc false
  def start(paths, test_coverage) do
    if function_exported?(:code, :coverage_support, 0) and apply(:code, :coverage_support, []) do
      :persistent_term.put(:repatch_line_counters, true)
    else
      :persistent_term.put(:repatch_non_native_coverage, true)
    end

    {next, test_coverage} = next_tool(test_coverage)
    hook = next.start(paths, test_coverage)

    case hook do
      nil ->
        fn -> cleanup() end

      _ ->
        fn ->
          cleanup()
          hook.()
        end
    end
  end

  defp cleanup do
    for name <-
          ~w[repatch_shared_hooks_enabled repatch_global_hooks_enabled repatch_history_enabled]a do
      :persistent_term.put(name, false)
    end
  end

  defp next_tool(opts) do
    with {nil, opts} <- next_tool(opts, [], nil) do
      {Mix.Tasks.Test.Coverage, opts}
    end
  end

  defp next_tool([{:tool, __MODULE__} | opts], acc, next) do
    next_tool(opts, acc, next)
  end

  defp next_tool([{:tool, tool} | opts], acc, nil) do
    next_tool(opts, [{:tool, tool} | acc], tool)
  end

  defp next_tool([{:tool, tool} | opts], acc, next) do
    next_tool(opts, [{:tool, tool} | acc], next)
  end

  defp next_tool([head | opts], acc, next) do
    next_tool(opts, [head | acc], next)
  end

  defp next_tool([], acc, next) do
    {next, :lists.reverse(acc)}
  end
end
