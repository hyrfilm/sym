defmodule Symd.SemanticTest do
  use ExUnit.Case, async: true

  alias Symd.{Semantic, Workspace}
  alias Symd.Lsp.Uri

  @typescript %{
    name: "typescript",
    command: "tls",
    args: ["--stdio"],
    extensions: [".ts", ".tsx"]
  }

  defp workspace(overrides) do
    struct!(
      %Workspace{
        root: "/nowhere",
        lsps: [@typescript],
        request: fn _lsp, method, _params -> flunk("unexpected request #{method}") end,
        sync: fn _lsp, path -> flunk("unexpected sync #{path}") end
      },
      overrides
    )
  end

  test "symbols flattens hierarchical document symbols in file order" do
    content = "class Parser {\n  parse(input: string) {}\n}\nfunction parse() {}\n"

    nested = [
      %{
        "name" => "Parser",
        "kind" => 5,
        "selectionRange" => %{"start" => %{"line" => 0, "character" => 6}},
        "children" => [
          %{
            "name" => "parse",
            "kind" => 6,
            "selectionRange" => %{"start" => %{"line" => 1, "character" => 2}}
          }
        ]
      },
      %{
        "name" => "parse",
        "kind" => 12,
        "selectionRange" => %{"start" => %{"line" => 3, "character" => 9}}
      }
    ]

    workspace =
      workspace(
        sync: fn @typescript, "/repo/parser.ts" -> {:ok, content} end,
        request: fn @typescript, "textDocument/documentSymbol", params ->
          assert params == %{"textDocument" => %{"uri" => "file:///repo/parser.ts"}}
          {:ok, nested}
        end
      )

    assert Semantic.symbols(workspace, "/repo/parser.ts") ==
             {:ok,
              %{
                "symbols" => [
                  %{
                    "name" => "Parser",
                    "kind" => "class",
                    "path" => "/repo/parser.ts",
                    "line" => 1,
                    "column" => 7
                  },
                  %{
                    "name" => "parse",
                    "kind" => "method",
                    "container" => "Parser",
                    "path" => "/repo/parser.ts",
                    "line" => 2,
                    "column" => 3
                  },
                  %{
                    "name" => "parse",
                    "kind" => "function",
                    "path" => "/repo/parser.ts",
                    "line" => 4,
                    "column" => 10
                  }
                ]
              }}
  end

  test "symbols accepts the flat SymbolInformation shape" do
    flat = [
      %{
        "name" => "parse",
        "kind" => 12,
        "containerName" => "",
        "location" => %{
          "uri" => "file:///repo/parser.ts",
          "range" => %{"start" => %{"line" => 0, "character" => 9}}
        }
      }
    ]

    workspace =
      workspace(
        sync: fn _lsp, _path -> {:ok, "function parse() {}"} end,
        request: fn _lsp, "textDocument/documentSymbol", _params -> {:ok, flat} end
      )

    assert {:ok, %{"symbols" => [symbol]}} = Semantic.symbols(workspace, "/repo/parser.ts")

    assert symbol == %{
             "name" => "parse",
             "kind" => "function",
             "path" => "/repo/parser.ts",
             "line" => 1,
             "column" => 10
           }
  end

  test "files no configured LSP answers for are rejected with the configured extensions" do
    assert Semantic.symbols(workspace([]), "/repo/main.py") ==
             {:error, {:no_lsp_for_path, "/repo/main.py", [".ts", ".tsx"]}}
  end

  @tag :tmp_dir
  test "positions cross the UTF-16 boundary correctly in both directions", %{tmp_dir: dir} do
    path = Path.join(dir, "u.ts")
    File.write!(path, "const 𝒇 = parse(𝒇)")
    uri = Uri.from_path(path)

    workspace =
      workspace(
        sync: fn @typescript, ^path -> File.read(path) end,
        request: fn @typescript, "textDocument/definition", params ->
          # Column 11 ("p" of parse) is UTF-16 offset 11: 𝒇 is two units.
          assert params == %{
                   "textDocument" => %{"uri" => uri},
                   "position" => %{"line" => 0, "character" => 11}
                 }

          # Offset 6 is 𝒇 itself, which is column 7.
          {:ok, [%{"uri" => uri, "range" => %{"start" => %{"line" => 0, "character" => 6}}}]}
        end
      )

    assert Semantic.definition(workspace, %{path: path, line: 1, column: 11}) ==
             {:ok, %{"definitions" => [%{"path" => path, "line" => 1, "column" => 7}]}}
  end

  @tag :tmp_dir
  test "definition by dotted name keeps only the exact container match", %{tmp_dir: dir} do
    path = Path.join(dir, "parser.ts")
    File.write!(path, "class Parser {\n  parse() {}\n}\nfunction parse() {}\n")

    info = fn name, kind, container, line, character ->
      %{
        "name" => name,
        "kind" => kind,
        "containerName" => container,
        "location" => %{
          "uri" => Uri.from_path(path),
          "range" => %{"start" => %{"line" => line, "character" => character}}
        }
      }
    end

    workspace =
      workspace(
        root: dir,
        sync: fn @typescript, seeded -> File.read(seeded) end,
        request: fn @typescript, "workspace/symbol", params ->
          assert params == %{"query" => "parse"}

          {:ok,
           [
             info.("parse", 12, "", 3, 9),
             info.("parse", 6, "Parser", 1, 2),
             info.("parser", 13, "", 0, 0)
           ]}
        end
      )

    assert Semantic.definition(workspace, "Parser.parse") ==
             {:ok,
              %{
                "definitions" => [
                  %{
                    "name" => "parse",
                    "kind" => "method",
                    "container" => "Parser",
                    "path" => path,
                    "line" => 2,
                    "column" => 3
                  }
                ]
              }}
  end

  test "an unknown name reports what the servers found instead" do
    workspace =
      workspace(
        root: "/nowhere-to-seed",
        sync: fn _lsp, _path -> {:ok, ""} end,
        request: fn _lsp, "workspace/symbol", _params ->
          {:ok,
           [
             %{"name" => "parser", "kind" => 13, "location" => %{}},
             %{"name" => "parsley", "kind" => 13}
           ]}
        end
      )

    assert Semantic.definition(workspace, "parse") ==
             {:error, {:symbol_not_found, "parse", ["parser", "parsley"]}}
  end

  @tag :tmp_dir
  test "references by name re-anchor on the identifier and group per symbol", %{tmp_dir: dir} do
    declaration = Path.join(dir, "parser.ts")
    usage = Path.join(dir, "use.ts")
    File.write!(declaration, "export function parse(input) {}\n")
    File.write!(usage, "import { parse } from \"./parser\"\n\nconst x = parse(1)\n")
    parent = self()

    workspace =
      workspace(
        root: dir,
        sync: fn @typescript, path ->
          send(parent, {:synced, path})
          File.read(path)
        end,
        request: fn
          @typescript, "workspace/symbol", %{"query" => "parse"} ->
            {:ok,
             [
               %{
                 "name" => "parse",
                 "kind" => 12,
                 "location" => %{
                   "uri" => Uri.from_path(declaration),
                   # The range starts at "export"; references needs "parse".
                   "range" => %{"start" => %{"line" => 0, "character" => 0}}
                 }
               }
             ]}

          @typescript, "textDocument/references", params ->
            assert params["position"] == %{"line" => 0, "character" => 16}
            assert params["context"] == %{"includeDeclaration" => true}

            {:ok,
             [
               %{
                 "uri" => Uri.from_path(usage),
                 "range" => %{"start" => %{"line" => 2, "character" => 10}}
               },
               %{
                 "uri" => Uri.from_path(declaration),
                 "range" => %{"start" => %{"line" => 0, "character" => 16}}
               }
             ]}
        end
      )

    assert {:ok, %{"matches" => [match]}} = Semantic.references(workspace, "parse")

    # The declaration range started at "export"; the symbol is re-anchored
    # on the identifier itself.
    assert match["symbol"] ==
             %{
               "name" => "parse",
               "kind" => "function",
               "path" => declaration,
               "line" => 1,
               "column" => 17
             }

    assert match["refs"] == [
             %{"path" => declaration, "line" => 1, "column" => 17},
             %{"path" => usage, "line" => 3, "column" => 11}
           ]

    assert_received {:synced, ^declaration}
  end

  test "heavy ambiguity returns candidates instead of a pile of lookups" do
    infos =
      for index <- 1..6 do
        %{
          "name" => "parse",
          "kind" => 12,
          "location" => %{
            "uri" => "file:///missing/f#{index}.ts",
            "range" => %{"start" => %{"line" => index, "character" => 0}}
          }
        }
      end

    workspace =
      workspace(
        root: "/nowhere-to-seed",
        sync: fn _lsp, _path -> {:ok, ""} end,
        request: fn
          _lsp, "workspace/symbol", _params ->
            {:ok, infos}

          _lsp, "textDocument/references", _params ->
            flunk("looked up references while ambiguous")
        end
      )

    assert {:ok, %{"candidates" => candidates}} = Semantic.references(workspace, "parse")
    assert length(candidates) == 6
    assert %{"name" => "parse", "kind" => "function", "line" => 2} = hd(candidates)
  end

  test "a broken server does not hide another server's answer" do
    other = %{name: "other", command: "x", args: [], extensions: [".zz"]}

    workspace =
      workspace(
        root: "/nowhere-to-seed",
        lsps: [other, @typescript],
        sync: fn _lsp, _path -> {:ok, ""} end,
        request: fn
          ^other, "workspace/symbol", _params ->
            {:error, {:server_exited, 1}}

          @typescript, "workspace/symbol", _params ->
            {:ok,
             [
               %{
                 "name" => "parse",
                 "kind" => 12,
                 "location" => %{
                   "uri" => "file:///missing/a.ts",
                   "range" => %{"start" => %{"line" => 0, "character" => 0}}
                 }
               }
             ]}
        end
      )

    assert {:ok, %{"definitions" => [_definition]}} = Semantic.definition(workspace, "parse")
  end

  test "when every server fails, the real error surfaces" do
    workspace =
      workspace(
        root: "/nowhere-to-seed",
        sync: fn _lsp, _path -> {:ok, ""} end,
        request: fn _lsp, "workspace/symbol", _params -> {:error, {:server_exited, 1}} end
      )

    assert Semantic.references(workspace, "parse") == {:error, {:server_exited, 1}}
  end
end
