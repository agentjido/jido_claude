defmodule Jido.Claude.Error do
  @moduledoc """
  Centralized error handling for Jido.Claude.
  """

  use Splode,
    error_classes: [
      invalid: Invalid,
      execution: Execution,
      config: Config,
      internal: Internal
    ],
    unknown_error: __MODULE__.Internal.UnknownError

  defmodule Invalid do
    @moduledoc false
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Execution do
    @moduledoc false
    use Splode.ErrorClass, class: :execution
  end

  defmodule Config do
    @moduledoc false
    use Splode.ErrorClass, class: :config
  end

  defmodule Internal do
    @moduledoc false
    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false
      defexception [:message, :details]
    end
  end

  defmodule InvalidInputError do
    @moduledoc "Raised when adapter input validation fails."
    @type t :: %__MODULE__{message: String.t() | nil, field: term(), value: term(), details: term()}
    defexception [:message, :field, :value, :details]
  end

  defmodule ExecutionFailureError do
    @moduledoc "Raised when Claude execution fails."
    @type t :: %__MODULE__{message: String.t() | nil, details: term()}
    defexception [:message, :details]
  end

  defmodule ConfigError do
    @moduledoc "Raised when Claude runtime configuration is invalid."
    @type t :: %__MODULE__{message: String.t() | nil, key: term(), details: term()}
    defexception [:message, :key, :details]
  end

  @doc "Creates a validation error."
  @spec validation_error(String.t(), map()) :: InvalidInputError.t()
  def validation_error(message, details \\ %{}) do
    field = Map.get(details, :field, Map.get(details, "field"))
    value = Map.get(details, :value, Map.get(details, "value"))

    extra_details =
      details
      |> Map.drop([:field, "field", :value, "value"])
      |> case do
        map when map_size(map) == 0 -> nil
        map -> map
      end

    InvalidInputError.exception(message: message, field: field, value: value, details: extra_details)
  end

  @doc "Creates an execution error."
  @spec execution_error(String.t(), map()) :: ExecutionFailureError.t()
  def execution_error(message, details \\ %{}) do
    ExecutionFailureError.exception(message: message, details: details)
  end

  @doc "Creates a configuration error."
  @spec config_error(String.t(), map()) :: ConfigError.t()
  def config_error(message, details \\ %{}) do
    key = Map.get(details, :key, Map.get(details, "key"))

    extra_details =
      details
      |> Map.drop([:key, "key"])
      |> case do
        map when map_size(map) == 0 -> nil
        map -> map
      end

    ConfigError.exception(message: message, key: key, details: extra_details)
  end
end
