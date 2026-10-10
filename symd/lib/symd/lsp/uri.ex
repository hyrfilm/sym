defmodule Symd.Lsp.Uri do
  @moduledoc """
  file:// URIs for LSP messages. Only local absolute paths are supported;
  anything else (untitled:, jar:, …) is reported as not a local file so a
  caller can skip that location instead of inventing a path for it.
  """

  def from_path(path), do: "file://" <> URI.encode(path, &(&1 == ?/ or URI.char_unreserved?(&1)))

  def to_path(uri) do
    case URI.parse(uri) do
      %URI{scheme: "file", path: path} when is_binary(path) -> {:ok, URI.decode(path)}
      _other -> :error
    end
  end
end
