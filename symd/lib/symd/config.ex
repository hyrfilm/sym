defmodule Symd.Config do
  @moduledoc """
  Reads the configured language servers out of TOML.

  The configuration points at language servers; it does not manage them.
  Each `[lsp.<name>]` table says how to start one server and which files it
  answers for:

      [lsp.typescript]
      command = "typescript-language-server"
      args = ["--stdio"]
      extensions = [".ts", ".tsx"]

  `command` is an executable name looked up on PATH, or a path resolved
  against this file's directory. Where that executable came from — nix, npm,
  a checkout — is deliberately not this tool's business.
  """

  @doc """
  Returns `{:ok, lsps}` with one entry per `[lsp.<name>]` table, sorted by
  name so extension lookups are deterministic, or `{:error, message}`.
  """
  def parse(toml) do
    case TomlElixir.decode(toml) do
      {:ok, data} -> extract(data)
      {:error, error} -> {:error, "invalid TOML: #{Exception.message(error)}"}
    end
  end

  defp extract(%{"lsp" => lsps}) when is_map(lsps) and map_size(lsps) > 0 do
    lsps
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {name, table}, {:ok, acc} ->
      case entry(name, table) do
        {:ok, lsp} -> {:cont, {:ok, [lsp | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp extract(_data),
    do: {:error, "expected at least one [lsp.<name>] table with command and extensions"}

  defp entry(name, %{"command" => command} = table)
       when is_binary(command) and byte_size(command) > 0 do
    with {:ok, args} <- args(name, Map.get(table, "args", [])),
         {:ok, extensions} <- extensions(name, Map.get(table, "extensions")) do
      {:ok, %{name: name, command: command, args: args, extensions: extensions}}
    end
  end

  defp entry(name, _table), do: {:error, "[lsp.#{name}] needs a non-empty command string"}

  defp args(name, args) do
    if is_list(args) and Enum.all?(args, &is_binary/1),
      do: {:ok, args},
      else: {:error, "[lsp.#{name}] args must be a list of strings"}
  end

  defp extensions(name, extensions) do
    if is_list(extensions) and extensions != [] and
         Enum.all?(extensions, &(is_binary(&1) and String.starts_with?(&1, "."))) do
      {:ok, Enum.map(extensions, &String.downcase/1)}
    else
      {:error, ~s([lsp.#{name}] extensions must be a non-empty list like [".ts", ".tsx"])}
    end
  end
end
