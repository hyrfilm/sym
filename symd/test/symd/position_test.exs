defmodule Symd.PositionTest do
  use ExUnit.Case, async: true

  alias Symd.Position

  # "𝒇" is U+1D453: one codepoint, two UTF-16 code units. The interesting
  # cases all sit after it, where the two counting schemes disagree.
  @line "const 𝒇 = parse(𝒇)"

  test "columns and UTF-16 offsets agree on ASCII" do
    assert Position.utf16_offset("const x", 1) == 0
    assert Position.utf16_offset("const x", 7) == 6
    assert Position.column("const x", 0) == 1
    assert Position.column("const x", 6) == 7
  end

  test "columns and UTF-16 offsets diverge after an astral codepoint" do
    # p of "parse" is codepoint column 11 but UTF-16 offset 11 too: ten
    # codepoints precede it and one of them is two units wide.
    assert Position.utf16_offset(@line, 11) == 11
    assert Position.column(@line, 11) == 11
    # 𝒇 itself: column 7, offset 6.
    assert Position.utf16_offset(@line, 7) == 6
    assert Position.column(@line, 6) == 7
  end

  test "out-of-range positions land just past what exists" do
    assert Position.utf16_offset("ab", 99) == 2
    assert Position.column("ab", 99) == 3
    assert Position.column("", 5) == 1
    # An offset inside a surrogate pair rounds to the following column.
    assert Position.column("𝒇x", 1) == 2
  end

  test "find_name lands on the identifier, not on a substring or keyword" do
    assert Position.find_name("export function parse(x) {}", "parse") == 17
    assert Position.find_name("reparse parse(", "parse") == 9
    assert Position.find_name("parse parse", "parse", 3) == 7
    assert Position.find_name("parse", "parse") == 1
  end

  test "find_name falls back to the caller's column when nothing matches" do
    assert Position.find_name("nothing here", "parse", 4) == 4
  end
end
