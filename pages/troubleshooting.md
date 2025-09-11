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

## System module patching

It looks like
```erlang
{error,badarg,[{ets,lookup,[repatch_global_hooks,{'Elixir.System',no_halt,0}],[{error_info,#{cause=>id,module=>erl_stdlib_errors}}]},{'Elixir.Repatch',dispatch_global,4,[{file,"lib/repatch.ex"},{line,1573}]},{'Elixir.System',no_halt,0,[{file,"lib/system.ex"},{line,1}]},{'Elixir.Kernel.CLI',run,1,[{file,"lib/kernel/cli.ex"},{line,56}]},{init,start_it,1,[]},{init,start_em,1,[]},{init,do_boot,3,[]}]}
Runtime terminating during boot ({badarg,[{ets,lookup,[repatch_global_hooks,{'Elixir.System',no_halt,0}],[{error_info,#{cause=>id,module=>erl_stdlib_errors}}]},{'Elixir.Repatch',dispatch_global,4,[{file,"lib/repatch.ex"},{line,1573}]},{'Elixir.System',no_halt,0,[{file,"lib/system.ex"},{line,1}]},{'Elixir.Kernel.CLI',run,1,[{file,"lib/kernel/cli.ex"},{line,56}]},{init,start_it,1,[]},{init,start_em,1,[]},{init,do_boot,3,[]}]})
```

and it can be fixed by specifying the System functions which can't be recompiled
since ExUnit uses them internally. The working example looks like this

```elixir
Repatch.setup(
  recompile: [System],
  recompile_except: [
    {System, :no_halt, 0},
    {System, :halt, 1}
  ]
)
```

## no case clause matching: {:error, :not_purged}

It looks like

```elixir
** (CaseClauseError) no case clause matching: {:error, :not_purged}
code: Repatch.patch(Req, :get, fn _, _ ->
stacktrace:
 (repatch 1.6.0) lib/repatch.ex:233: Repatch.recompile/2
 (repatch 1.6.0) lib/repatch.ex:760: Repatch.patch/4
```

and it is caused when frequently used module is patched and
during the patch, some of the processes calls the module and prevents it from
purging completely.

It can be fixed by specifying this module in the `recompile` option of `Repatch.setup/1` call.

For example,

```elixir
Repatch.setup(recompile: [Req])
```

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
