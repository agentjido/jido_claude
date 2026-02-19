defmodule JidoClaude.CLI.Runner.Result do
  @moduledoc """
  Validated result returned by `JidoClaude.CLI.Runner`.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              raw_output: Zoi.string() |> Zoi.default(""),
              events: Zoi.array(Zoi.map()) |> Zoi.default([]),
              result_text: Zoi.string() |> Zoi.nullish(),
              status: Zoi.atom(),
              error: Zoi.string() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, value} ->
        value

      {:error, reason} ->
        raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end
end
