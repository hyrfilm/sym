defmodule Symd.Config do
  @moduledoc """
  Reads the profile fields out of TOML and hands them back as plain data.

  This module doesn't decide whether a backend exists or what a location means.
  That happens when the service builds the profile. Keeping those decisions out
  of parsing means a new backend doesn't need a new parser.
  """

  @doc """
  Returns `{:ok, %{name: ..., type: ..., location: ...}}` or `{:error, message}`.
  The TOML library handles syntax errors; we only extract the fields we need.
  Values pass through unchanged, including relative paths and unknown types.
  """
  def parse(toml) do
    case TomlElixir.decode(toml) do
      {:ok, data} -> extract(data)
      {:error, error} -> {:error, "invalid TOML: #{Exception.message(error)}"}
    end
  end

  # Matching the required keys also lets unrelated settings pass without
  # teaching this parser about every future option.
  defp extract(%{"profile" => %{"name" => name, "type" => type, "location" => location}}),
    do: {:ok, %{name: name, type: type, location: location}}

  defp extract(_data), do: {:error, "expected [profile] with name, type, and location"}
end
