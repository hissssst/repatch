defmodule Repatch.Recompiler do
  @moduledoc false
  # Contains all logic related to recompiling the module with
  # implementation which dispatches to hooks

  @generated [generated: true]

  @spec recompile(module()) :: {:ok, binary()} | {:error, any()}
  def recompile(module) do
    with(
      {:module, ^module} <- Code.ensure_loaded(module),
      {:ok, bin} <- binary(module),
      {:ok, compiler_options} <- compiler_options(bin),
      {:ok, forms} <- abstract_forms(bin)
    ) do
      forms = reload(forms, module)

      :code.purge(module)
      :code.delete(module)

      with :ok <- compile(forms, compiler_options) do
        {:ok, bin}
      end
    end
  end

  @spec super_name(String.Chars.t()) :: atom()
  def super_name(function) do
    :"REPATCH-#{function}"
  end

  @spec super_name_string(String.Chars.t()) :: binary()
  def super_name_string(function) do
    "REPATCH-#{function}"
  end

  @spec private_name(String.Chars.t()) :: atom()
  def private_name(function) do
    :"REPATCH-PRIVATE-#{function}"
  end

  @spec generated?(atom()) :: boolean()
  def generated?(function) do
    case :erlang.atom_to_binary(function) do
      "REPATCH-" <> _ -> true
      _ -> false
    end
  end

  @spec load_binary(module(), binary()) :: :ok | {:error, any()}
  def load_binary(module, binary) do
    sticky = unstick_module(module)

    try do
      with {:module, ^module} <- :code.load_binary(module, ~c"", binary) do
        :ok
      end
    after
      if sticky do
        :code.stick_mod(module)
      end
    end
  end

  ## Privates

  defp compiler_options(binary) do
    case :beam_lib.chunks(binary, [:compile_info]) do
      {:ok, {_, [compile_info: info]}} ->
        filtered_options =
          case Keyword.fetch(info, :options) do
            {:ok, options} ->
              filter_compiler_options(options)

            :error ->
              []
          end

        {:ok, filtered_options}

      {:error, :beam_lib, details} ->
        reason = elem(details, 0)
        {:error, reason}

      _ ->
        {:error, :compiler_options_unavailable}
    end
  end

  defp filter_compiler_options([]), do: []

  defp filter_compiler_options([{:parse_transform, _} | tail]) do
    filter_compiler_options(tail)
  end

  defp filter_compiler_options([o | tail]) when o in ~w[
      from_core makedeps_side_effects
      warn_missing_doc_function
      warn_missing_doc_callback
      warn_missing_spec_documented
  ]a do
    filter_compiler_options(tail)
  end

  defp filter_compiler_options([head | tail]) do
    [head | filter_compiler_options(tail)]
  end

  defp unstick_module(module) do
    if :code.is_sticky(module) do
      :code.unstick_mod(module)
    else
      false
    end
  end

  defp abstract_forms(binary) do
    case :beam_lib.chunks(binary, [:abstract_code]) do
      {:ok, {_, [abstract_code: {:raw_abstract_v1, abstract_forms}]}} ->
        {:ok, abstract_forms}

      {:error, :beam_lib, details} ->
        {:error, {:abstract_forms_unavailable, details}}

      _ ->
        {:error, {:abstract_forms_unavailable, []}}
    end
  end

  defp binary(module) do
    case :code.get_object_code(module) do
      {^module, binary, _} ->
        {:ok, binary}

      :error ->
        {:error, :binary_unavailable}
    end
  end

  defp compile(abstract_forms, compiler_options) do
    options = Enum.uniq([:return_errors, :debug_info | compiler_options])

    case :compile.forms(abstract_forms, options) do
      {:ok, module, binary} ->
        load_binary(module, binary)

      {:ok, module, binary, _} ->
        load_binary(module, binary)

      errors ->
        {:error, {:abstract_forms_invalid, abstract_forms, errors}}
    end
  end

  defp reload(abstract_forms, module) do
    traverse(abstract_forms, [], module, [])
  end

  defp traverse([head | tail], exports, module, acc) do
    case head do
      {:attribute, _, :export, old_exports} ->
        exports_and_supers =
          Enum.flat_map(old_exports, fn
            x when x in [__info__: 1, module_info: 0, module_info: 1] ->
              [x]

            {name, arity} ->
              [
                {name, arity},
                {super_name(name), arity}
              ]
          end)

        traverse(tail, exports ++ exports_and_supers, module, acc)

      {:attribute, anno, :compile, options} ->
        case filter_compile_options(options) do
          [] ->
            traverse(tail, exports, module, acc)

          options ->
            form = {:attribute, anno, :compile, options}
            traverse(tail, exports, module, [form | acc])
        end

      {:attribute, _anno, :import, _} = keep ->
        traverse(tail, exports, module, [keep | acc])

      {:function, _, name, _, _} = function when name in ~w[__info__ module_info]a ->
        traverse(tail, exports, module, [function | acc])

      {:function, anno, name, arity, clauses} ->
        if {name, arity} in exports do
          old_name = super_name(name)
          exports = [{old_name, arity} | exports]
          acc = function(module, anno, name, old_name, arity, clauses) ++ acc
          traverse(tail, exports, module, acc)
        else
          old_name = super_name(name)
          private_name = private_name(name)
          exports = [{old_name, arity}, {private_name, arity} | exports]

          acc =
            private_function(module, anno, name, old_name, private_name, arity, clauses) ++ acc

          traverse(tail, exports, module, acc)
        end

      _ ->
        traverse(tail, exports, module, acc)
    end
  end

  defp traverse([], exports, module, acc) do
    exports = Enum.uniq(exports)

    [
      {:attribute, @generated, :module, module},
      {:attribute, @generated, :export, exports} | Enum.reverse(acc)
    ]
  end

  defp function(module, anno, name, old_name, arity, old_clauses) do
    clause = {
      :clause,
      @generated,
      patterns(arity),
      [],
      body(module, name, arity, old_name)
    }

    new = {:function, @generated, name, arity, [clause]}
    old = {:function, anno, old_name, arity, old_clauses}
    [new, old]
  end

  defp private_function(module, anno, name, old_name, private_name, arity, old_clauses) do
    clause = {
      :clause,
      @generated,
      patterns(arity),
      [],
      body(module, name, arity, old_name)
    }

    private_clause = {
      :clause,
      @generated,
      patterns(arity),
      [],
      [{:call, @generated, {:atom, @generated, name}, patterns(arity)}]
    }

    new = {:function, @generated, name, arity, [clause]}
    private = {:function, @generated, private_name, arity, [private_clause]}
    old = {:function, anno, old_name, arity, old_clauses}

    [new, private, old]
  end

  defp patterns(0) do
    []
  end

  defp patterns(arity) do
    Enum.map(1..arity, fn position ->
      {:var, @generated, :"_arg#{position}"}
    end)
  end

  defp arguments(0) do
    {nil, @generated}
  end

  defp arguments(arity) do
    {:cons, @generated, {:var, @generated, :"_arg#{arity}"}, arguments(arity - 1)}
  end

  defp body(module, name, arity, old_name) do
    result = {:var, @generated, :"result#{:erlang.unique_integer([:positive])}"}

    [
      {:case, @generated,
       {:call, @generated,
        {:remote, @generated, {:atom, @generated, Repatch}, {:atom, @generated, :dispatch}},
        [
          {:atom, @generated, module},
          {:atom, @generated, name},
          {:integer, @generated, arity},
          arguments(arity)
        ]},
       [
         {:clause, @generated, [{:tuple, @generated, [{:atom, @generated, :ok}, result]}], [],
          [result]},
         {:clause, @generated, [{:atom, @generated, :pass}], [],
          [
            {:call, @generated, {:atom, @generated, old_name}, patterns(arity)}
          ]}
       ]}
    ]
  end

  defp filter_compile_options(:no_auto_import) do
    :no_auto_import
  end

  defp filter_compile_options({:no_auto_import, _} = option) do
    option
  end

  defp filter_compile_options(options) when is_list(options) do
    Enum.filter(options, fn
      :no_auto_import ->
        true

      {:no_auto_import, _} ->
        true

      _ ->
        false
    end)
  end

  defp filter_compile_options(_) do
    []
  end
end
