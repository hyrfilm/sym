defmodule Symd.Position do
  @moduledoc """
  Converts between our wire columns and LSP character offsets.

  Our protocol counts 1-based codepoint columns, the way compilers and grep
  do. LSP positions count 0-based UTF-16 code units within the line. The two
  agree on ASCII and drift apart on anything beyond it, so every conversion
  needs the text of the line it points into.
  """

  @doc "0-based UTF-16 offset for a 1-based codepoint column."
  def utf16_offset(line, column) when column >= 1 do
    line
    |> String.to_charlist()
    |> Enum.take(column - 1)
    |> Enum.reduce(0, &(&2 + width(&1)))
  end

  @doc """
  1-based codepoint column for a 0-based UTF-16 offset. An offset inside a
  surrogate pair or past the end of the line lands on the next column.
  """
  def column(line, offset) when offset >= 0 do
    column(String.to_charlist(line), offset, 1)
  end

  defp column(_codepoints, offset, column) when offset <= 0, do: column
  defp column([], _offset, column), do: column

  defp column([codepoint | rest], offset, column),
    do: column(rest, offset - width(codepoint), column + 1)

  defp width(codepoint) when codepoint > 0xFFFF, do: 2
  defp width(_codepoint), do: 1

  @doc """
  1-based column where `name` appears as a whole identifier, at or after
  `from_column`; `from_column` itself when it doesn't. Language servers often
  anchor a symbol's range at its first keyword (`export function parse…`),
  while definition and references want the cursor on the identifier.
  """
  def find_name(line, name, from_column \\ 1) do
    codepoints = String.to_charlist(line)
    target = String.to_charlist(name)
    search(codepoints, target, 1, max(from_column, 1), nil) || from_column
  end

  defp search([], _target, _column, _minimum, _previous), do: nil

  defp search([head | rest] = codepoints, target, column, minimum, previous) do
    if column >= minimum and not identifier?(previous) and whole_word?(codepoints, target) do
      column
    else
      search(rest, target, column + 1, minimum, head)
    end
  end

  defp whole_word?(rest, []), do: rest == [] or not identifier?(hd(rest))
  defp whole_word?([codepoint | rest], [codepoint | target]), do: whole_word?(rest, target)
  defp whole_word?(_codepoints, _target), do: false

  defp identifier?(nil), do: false
  defp identifier?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_
end
