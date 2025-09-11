ExUnit.start()

Repatch.setup(
  enable_global: true,
  recompile: [System],
  recompile_except: [
    {System, :no_halt, 0},
    {System, :halt, 1}
  ]
)

Repatch.Application.setup()
