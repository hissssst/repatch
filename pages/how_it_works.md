# How it works

In order to change implementation of the function of already compiled module, `Repatch`
performs recompilation of the module which substitutes every function in the module
with the call to dispatcher function which falls back to original implementation when
no override is found in dispatcher.

So, there are two parts in `Repatch`: recompiler and dispatcher

## Recompiler

Recompiler relies on abstract_forms of the module (that's why it's important to compile
modules with `debug_info` erlang/elixir compiler option). It basically takes
every function in the module and generates a super (aka original or old) version
of the function with the original implementation except that it will have a different name now and
a function with the original name but a different implementation, which will call dispatcher or
pass the arguments to the first function if there's nothing in dispatcher. Plus, recompiler
also generates a special public function for every private one, which just passes call to the original
private one

## Dispatcher

For every function in patched module, dispatcher will be called first. It will first
insert a history entry (if history is enabled) and then it will lookup into process dictionary for
the local patches. Then (if shared patches are enabled) it will look into shared patches ets tables
to check if there are any shared functions or allowances. And then (if global patches are enabled)
it will look into global patches table. Finally, when no patches were found, it will return value
which would indicate that original implementation must be called.

## Comments

This page describes that in worst case, dispatcher will call process dictionary and lookup into 3 ets tables.
It is okay for function which are called not very frequently during a test suite, but it is not good when function is
called a lot of times during the test case (like recursive list traversal functions), it will introduce
visible overhead. To reduce it, one should disable unused modes and history or take other actions from "Performance tips" guide
