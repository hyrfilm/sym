defmodule Symd.Lsp.WireTest do
  use ExUnit.Case, async: true

  alias Symd.Lsp.Wire

  test "encode produces a frame that decode reads back" do
    message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}
    frame = message |> Wire.encode() |> IO.iodata_to_binary()

    assert {:ok, ^message, ""} = Wire.decode(frame)
  end

  test "decodes across arbitrary chunk boundaries" do
    frame = %{"id" => 7} |> Wire.encode() |> IO.iodata_to_binary()

    # Every split point of the frame must yield :more, then the message.
    for split <- 0..(byte_size(frame) - 1) do
      <<first::binary-size(^split), second::binary>> = frame
      assert Wire.decode(first) in [:more, {:ok, %{"id" => 7}, ""}]
      assert {:ok, %{"id" => 7}, ""} = Wire.decode(first <> second)
    end
  end

  test "returns the rest of the buffer when messages arrive back to back" do
    buffer =
      IO.iodata_to_binary([Wire.encode(%{"id" => 1}), Wire.encode(%{"id" => 2})])

    assert {:ok, %{"id" => 1}, rest} = Wire.decode(buffer)
    assert {:ok, %{"id" => 2}, ""} = Wire.decode(rest)
  end

  test "tolerates extra headers and strange casing" do
    body = ~s({"id":3})

    frame =
      "Content-Type: application/vscode-jsonrpc\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <>
        body

    assert {:ok, %{"id" => 3}, ""} = Wire.decode(frame)
  end

  test "reports stream damage instead of guessing" do
    assert {:error, :missing_content_length} = Wire.decode("Content-Type: x\r\n\r\n{}")
    assert {:error, :invalid_message} = Wire.decode("Content-Length: 4\r\n\r\nnope")
    assert {:error, :header_overflow} = Wire.decode(String.duplicate("x", 20_000))
  end
end
