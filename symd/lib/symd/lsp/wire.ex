defmodule Symd.Lsp.Wire do
  @moduledoc """
  LSP base-protocol framing: a Content-Length header block, then a JSON body.

  These are pure functions over binaries so framing can be tested without a
  port. `decode/1` works on an accumulating buffer and hands back the rest,
  because a port delivers chunks with no respect for message boundaries.
  """

  @max_headers 16_384

  @doc "Frames one message for the wire."
  def encode(message) do
    body = JSON.encode_to_iodata!(message)
    ["Content-Length: ", Integer.to_string(IO.iodata_length(body)), "\r\n\r\n", body]
  end

  @doc """
  Takes one complete message off the front of the buffer.

  Returns `{:ok, message, rest}`, `:more` when the buffer holds only part of a
  message, or `{:error, reason}`. An error is fatal to the stream: byte
  framing has no way to find the start of the next message after garbage.
  """
  def decode(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        if byte_size(buffer) > @max_headers, do: {:error, :header_overflow}, else: :more

      {header_end, 4} ->
        <<header::binary-size(^header_end), "\r\n\r\n", rest::binary>> = buffer

        with {:ok, length} <- content_length(header) do
          case rest do
            <<body::binary-size(^length), remainder::binary>> -> parse(body, remainder)
            _incomplete -> :more
          end
        end
    end
  end

  defp content_length(header) do
    header
    |> String.split("\r\n")
    |> Enum.find_value({:error, :missing_content_length}, fn line ->
      with [name, value] <- String.split(line, ":", parts: 2),
           "content-length" <- name |> String.trim() |> String.downcase(),
           {length, ""} when length >= 0 <- Integer.parse(String.trim(value)) do
        {:ok, length}
      else
        _other -> nil
      end
    end)
  end

  defp parse(body, remainder) do
    case JSON.decode(body) do
      {:ok, message} when is_map(message) -> {:ok, message, remainder}
      _other -> {:error, :invalid_message}
    end
  end
end
