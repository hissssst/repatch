# Troubleshooting

Just a quick list with common problems

## `ets` table does not exist

It looks like

```
** (ArgumentError) errors were found at the given arguments:

 * 1st argument: the table identifier does not refer to an existing ETS table
```

And it indicates that you either didn't call `Repatch.setup/1` at all or called
it with some modes or options disabled and used these modes or options later.

To fix it, add correct `Repatch.setup` call.

## Inconsistent tests performance

If you run your tests with options like `--slowest` and each run takes different
amount of time, it means that some tests do on-demand module recompilation.

To fix it, you need to find all modules patched in these tests and then pass
them to `recompile` option in `Repatch.setup/1` call

## Coverage

If you call tests with `mix test --cover` and get something like this

```elixir
14:11:49.918 [error] Error in process #PID<0.787.0> with exit value:
{:badarg,
 [
   {:code, :get_coverage, [:cover_id_line, X],
    [error_info: %{module: :erl_kernel_errors}]},
   {:cover, :native_move, 1, [file: ~c"cover.erl", line: 2367]},
   {:cover, :move_counters, 2, [file: ~c"cover.erl", line: 2318]},
   {:cover, :collect_module, 2, [file: ~c"cover.erl", line: 2426]},
   {:cover, :do_parallel_analysis_to_file, 5, [file: ~c"cover.erl", line: 2655]}
 ]}
```

You should add `Repatch.CoverTool` to the test coverage tools options as described in the module's doc.
