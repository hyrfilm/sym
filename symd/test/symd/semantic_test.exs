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

  # Name queries only consult servers whose extensions exist in the
  # workspace, so tests of them need a root containing matching files.
  defp seedable!(dir, files) do
    for file <- files, do: File.write!(Path.join(dir, file), "")
    dir
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

  @tag :tmp_dir
  test "an unknown name reports what the servers found instead", %{tmp_dir: dir} do
    workspace =
      workspace(
        root: seedable!(dir, ["a.ts"]),
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

  @tag :tmp_dir
  test "heavy ambiguity returns candidates instead of a pile of lookups", %{tmp_dir: dir} do
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
        root: seedable!(dir, ["a.ts"]),
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

  @tag :tmp_dir
  test "elixir-style qualified names match bare, dotted, and arity queries", %{tmp_dir: dir} do
    # dexter reports "Symd.Servers.stop_root/1" as the whole name; tsserver
    # would report "stop_root" with containerName. Both must be findable
    # with the same queries — including pasting a suggestion back in.
    infos = [
      %{
        "name" => "Symd.Servers.stop_root/1",
        "kind" => 12,
        # dexter repeats the module path here; it must not print doubled.
        "containerName" => "Symd.Servers",
        "location" => %{
          "uri" => "file:///missing/servers.ex",
          "range" => %{"start" => %{"line" => 30, "character" => 2}}
        }
      },
      %{
        "name" => "Other.Module.stop_root/2",
        "kind" => 12,
        "location" => %{
          "uri" => "file:///missing/other.ex",
          "range" => %{"start" => %{"line" => 5, "character" => 2}}
        }
      }
    ]

    workspace =
      workspace(
        root: seedable!(dir, ["a.ts"]),
        sync: fn _lsp, _path -> {:ok, ""} end,
        request: fn _lsp, "workspace/symbol", _params -> {:ok, infos} end
      )

    both = fn name ->
      case Semantic.definition(workspace, name) do
        {:ok, %{"definitions" => definitions}} -> Enum.map(definitions, & &1["path"])
        {:error, {:symbol_not_found, _name, _similar}} -> :not_found
      end
    end

    assert both.("stop_root") == ["/missing/servers.ex", "/missing/other.ex"]
    assert both.("Servers.stop_root") == ["/missing/servers.ex"]
    assert both.("Symd.Servers.stop_root") == ["/missing/servers.ex"]
    assert both.("Symd.Servers.stop_root/1") == ["/missing/servers.ex"]
    assert both.("stop_root/2") == ["/missing/other.ex"]
    assert both.("stop_root/3") == :not_found
    assert both.("Wrong.stop_root") == :not_found

    assert {:ok, %{"definitions" => [definition]}} =
             Semantic.definition(workspace, "Symd.Servers.stop_root/1")

    assert definition["name"] == "Symd.Servers.stop_root/1"
    refute Map.has_key?(definition, "container")
  end

  @tag :tmp_dir
  test "a broken server does not hide another server's answer", %{tmp_dir: dir} do
    other = %{name: "other", command: "x", args: [], extensions: [".zz"]}

    workspace =
      workspace(
        root: seedable!(dir, ["a.zz", "a.ts"]),
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

  @tag :tmp_dir
  test "when every server fails, the real error surfaces, naming the server", %{tmp_dir: dir} do
    workspace =
      workspace(
        root: seedable!(dir, ["a.ts"]),
        sync: fn _lsp, _path -> {:ok, ""} end,
        request: fn _lsp, "workspace/symbol", _params -> {:error, {:server_exited, 1}} end
      )

    assert Semantic.references(workspace, "parse") ==
             {:error, {:lsp_failed, "typescript", {:server_exited, 1}}}
  end

  @tag :tmp_dir
  test "a server with no matching files is never consulted or started", %{tmp_dir: dir} do
    # The request stub only accepts @typescript: a call for the other server
    # would crash the query. dexter in a TypeScript-only repo stays cold.
    other = %{name: "other", command: "x", args: [], extensions: [".zz"]}

    workspace =
      workspace(
        root: seedable!(dir, ["a.ts"]),
        lsps: [other, @typescript],
        sync: fn @typescript, _path -> {:ok, ""} end,
        request: fn @typescript, "workspace/symbol", _params ->
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

  @tag :tmp_dir
  test "a workspace no configured server has files for is a clear error", %{tmp_dir: dir} do
    workspace =
      workspace(
        root: dir,
        sync: fn _lsp, path -> flunk("synced #{path} in an unrelated workspace") end,
        request: fn _lsp, method, _params -> flunk("sent #{method} in an unrelated workspace") end
      )

    assert Semantic.definition(workspace, "parse") ==
             {:error, {:no_lsp_for_workspace, dir, [".ts", ".tsx"]}}
  end

  @tag :tmp_dir
  test "name queries seed a file below the root, source directories first", %{tmp_dir: dir} do
    # A root-level file is usually build config (vite.config.ts) belonging
    # to a side project; seeding it leaves tsserver unable to answer
    # workspace/symbol for the application's own symbols.
    File.write!(Path.join(dir, "vite.config.ts"), "")
    File.mkdir_p!(Path.join(dir, "e2e"))
    File.write!(Path.join(dir, "e2e/smoke.ts"), "")
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "src/app.ts"), "")

    parent = self()

    workspace =
      workspace(
        root: dir,
        sync: fn @typescript, path ->
          send(parent, {:seeded, path})
          {:ok, ""}
        end,
        request: fn @typescript, "workspace/symbol", _params -> {:ok, []} end
      )

    assert {:error, {:symbol_not_found, _name, _similar}} =
             Semantic.definition(workspace, "Missing")

    assert_received {:seeded, seeded}
    assert seeded == Path.join(dir, "src/app.ts")
  end

  @tag :tmp_dir
  test "a root-level file still seeds when nothing deeper exists", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "vite.config.ts"), "")

    parent = self()

    workspace =
      workspace(
        root: dir,
        sync: fn @typescript, path ->
          send(parent, {:seeded, path})
          {:ok, ""}
        end,
        request: fn @typescript, "workspace/symbol", _params -> {:ok, []} end
      )

    assert {:error, {:symbol_not_found, _name, _similar}} =
             Semantic.definition(workspace, "Missing")

    assert_received {:seeded, seeded}
    assert seeded == Path.join(dir, "vite.config.ts")
  end
end
