defmodule Symd.DirectoriesIntegrationTest do
  use ExUnit.Case, async: true

  alias Symd.{Config, Semantic, Workspace}
  alias Symd.Lsp.{Client, Uri}

  @server System.find_executable("typescript-language-server")
  @moduletag skip: is_nil(@server)
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    files = %{
      "tsconfig.json" =>
        ~s({"files":[],"references":[{"path":"./tsconfig.app.json"},{"path":"./tsconfig.test.json"},{"path":"./tsconfig.tools.json"}]}),
      "tsconfig.app.json" =>
        ~s({"compilerOptions":{"noEmit":true,"paths":{"@/*":["./src/*"]}},"include":["src/**/*.ts"]}),
      "tsconfig.test.json" =>
        ~s({"extends":"./tsconfig.app.json","include":["src/**/*.ts","test/**/*.ts"]}),
      "tsconfig.tools.json" =>
        ~s({"compilerOptions":{"noEmit":true},"include":["tools/**/*.ts"]}),
      "src/00-seed.ts" => "export {};\n",
      "src/lib.ts" => "export function appFunction() {}\n",
      "test/00-seed.ts" => "export {};\n",
      "test/nested/lib.test.ts" =>
        "import { appFunction } from '@/lib';\nexport function testOnlyHelper() { appFunction(); }\n",
      "test/use.ts" => "import { testOnlyHelper } from './nested/lib.test';\ntestOnlyHelper();\n",
      "tools/build.ts" => "export function buildOnlyHelper() {}\n"
    }

    for {file, content} <- files do
      path = Path.join(root, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    {:ok, [lsp]} =
      Config.parse("""
      [lsp.ts]
      command = "typescript-language-server"
      args = ["--stdio"]
      extensions = [".ts"]
      directories = ["src/", "test/"]
      """)

    client = start_supervised!({Client, command: @server, args: ["--stdio"], root: root})

    workspace = %Workspace{
      root: root,
      lsps: [lsp],
      sync: fn _lsp, path -> Client.sync(client, path) end,
      request: fn _lsp, method, params -> Client.request(client, method, params) end,
      settle: fn _lsp -> Client.await_quiet(client) end
    }

    %{workspace: workspace, root: root, client: client}
  end

  test "a cold positional reference query includes tests in another project", context do
    assert {:ok, %{"matches" => [%{"refs" => refs}]}} =
             Semantic.references(context.workspace, %{
               path: Path.join(context.root, "src/lib.ts"),
               line: 1,
               column: 17
             })

    assert_test_references(refs, context.root)
    assert_open_files(context, ["src/00-seed.ts", "test/00-seed.ts", "src/lib.ts"])
  end

  test "cold named references and repeated name queries include the seeded test project",
       context do
    workspace = context.workspace

    assert {:ok, %{"matches" => [%{"refs" => refs}]}} =
             Semantic.references(workspace, "appFunction")

    assert_test_references(refs, context.root)
    assert_open_files(context, ["src/00-seed.ts", "test/00-seed.ts", "src/lib.ts"])

    for name <- ["testOnlyHelper", "appFunction", "testOnlyHelper"] do
      assert {:ok, %{"definitions" => [%{"name" => ^name}]}} =
               Semantic.definition(workspace, name)
    end

    assert {:ok, %{"matches" => [%{"refs" => refs}]}} =
             Semantic.references(workspace, "testOnlyHelper")

    assert Enum.any?(refs, &(&1["path"] == Path.join(context.root, "test/use.ts")))
    assert {:ok, _} = Semantic.definition(workspace, "appFunction")
  end

  test "cold test name lookup opens only the two representative files", context do
    [lsp] = context.workspace.lsps
    workspace = %{context.workspace | lsps: [%{lsp | directories: ["test/", "src/"]}]}
    assert {:ok, %{"definitions" => [_]}} = Semantic.definition(workspace, "testOnlyHelper")
    assert_open_files(context, ["src/00-seed.ts", "test/00-seed.ts"])
    assert {:ok, _} = Semantic.definition(workspace, "appFunction")
    assert {:ok, _} = Semantic.definition(workspace, "testOnlyHelper")
  end

  test "previously opened non-seed files follow disk edits and deletions", context do
    workspace = context.workspace
    path = Path.join(context.root, "test/editable.ts")
    File.write!(path, "export function initialHelper() {}\n")
    assert {:ok, _} = Semantic.symbols(workspace, path)

    File.write!(
      path,
      "import { appFunction } from '@/lib';\nexport function renamedHelper() { appFunction(); }\n"
    )

    assert {:ok, %{"definitions" => [_]}} = Semantic.definition(workspace, "renamedHelper")

    assert {:error, {:symbol_not_found, "initialHelper", _}} =
             Semantic.definition(workspace, "initialHelper")

    assert {:ok, %{"matches" => [%{"refs" => refs}]}} =
             Semantic.references(workspace, "appFunction")

    assert Enum.any?(refs, &(&1["path"] == path))

    File.rm!(path)

    assert {:ok, %{"matches" => [%{"refs" => refs}]}} =
             Semantic.references(workspace, "appFunction")

    refute Enum.any?(refs, &(&1["path"] == path))
  end

  test "directory seeds leave disconnected-project name scope to the server", context do
    [lsp] = context.workspace.lsps
    workspace = %{context.workspace | lsps: [%{lsp | directories: ["src/", "test/", "tools/"]}]}
    assert {:ok, _} = Semantic.definition(workspace, "buildOnlyHelper")

    # TLS scopes workspace/symbol to the last accessed file's projects.
    assert {:error, {:symbol_not_found, "testOnlyHelper", _}} =
             Semantic.definition(workspace, "testOnlyHelper")

    assert {:ok, _} = Semantic.symbols(workspace, Path.join(context.root, "test/00-seed.ts"))
    assert {:ok, _} = Semantic.definition(workspace, "testOnlyHelper")

    assert {:error, {:symbol_not_found, "buildOnlyHelper", _}} =
             Semantic.definition(workspace, "buildOnlyHelper")
  end

  defp assert_open_files(context, paths) do
    expected = MapSet.new(paths, &Uri.from_path(Path.join(context.root, &1)))

    assert context.client
           |> :sys.get_state()
           |> Map.fetch!(:documents)
           |> Map.keys()
           |> MapSet.new() == expected
  end

  defp assert_test_references(refs, root) do
    test_path = Path.join(root, "test/nested/lib.test.ts")
    assert Enum.any?(refs, &(&1["path"] == test_path and &1["line"] == 1))
    assert Enum.any?(refs, &(&1["path"] == test_path and &1["line"] == 2))
  end
end
