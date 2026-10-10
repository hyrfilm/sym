defmodule Symd.ServiceTest do
  use ExUnit.Case, async: true

  alias Symd.{Service, Workspace}

  defp untouchable do
    %Workspace{
      root: "/",
      lsps: [],
      request: fn _lsp, method, _params -> flunk("unexpected request #{method}") end,
      sync: fn _lsp, path -> flunk("unexpected sync #{path}") end
    }
  end

  # The relative command in sym.toml resolves against the config file, not
  # the current directory, so symd behaves the same wherever it's started.
  @tag :tmp_dir
  test "startup resolves the root and config-relative commands", %{tmp_dir: dir} do
    config = Path.join(dir, "sym.toml")

    File.write!(config, """
    [lsp.typescript]
    command = "typescript-language-server"
    args = ["--stdio"]
    extensions = [".ts"]

    [lsp.local]
    command = "./tools/lsp"
    extensions = [".zz"]
    """)

    assert {:ok, %Workspace{} = workspace} = Service.open(config)
    assert workspace.root == dir

    assert [
             %{name: "local", command: local},
             %{name: "typescript", command: "typescript-language-server"}
           ] =
             workspace.lsps

    assert local == Path.join(dir, "tools/lsp")
  end

  test "startup reports missing or invalid configuration" do
    assert {:error, :enoent} = Service.open("/does/not/exist/sym.toml")
  end

  test "invalid requests never reach the semantic layer" do
    workspace = untouchable()

    for json <- [
          "{",
          "null",
          ~s({"op":"unknown"}),
          ~s({"op":"symbols"}),
          ~s({"op":"symbols","path":""}),
          ~s({"op":"symbols","path":"/f.ts","extra":true}),
          ~s({"op":"def"}),
          ~s({"op":"def","name":""}),
          ~s({"op":"refs","name":"x","path":"/f.ts"}),
          ~s({"op":"def","path":"/f.ts","line":0,"column":1}),
          ~s({"op":"refs","path":"/f.ts","line":"1","column":1}),
          ~s({"op":"status","extra":true})
        ] do
      assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
               Service.request(workspace, json)
    end
  end

  test "semantic results and failures become reply envelopes with stable codes" do
    lsp = %{name: "ts", command: "x", args: [], extensions: [".ts"]}

    working = %{
      untouchable()
      | lsps: [lsp],
        sync: fn ^lsp, _path -> {:ok, ""} end,
        request: fn ^lsp, "textDocument/documentSymbol", _params -> {:ok, []} end
    }

    assert Service.handle(working, %{"op" => "symbols", "path" => "/repo/a.ts"}) ==
             %{"ok" => true, "result" => %{"symbols" => []}}

    assert %{"ok" => false, "error" => %{"code" => "unsupported_file", "message" => message}} =
             Service.handle(working, %{"op" => "symbols", "path" => "/repo/a.py"})

    assert message =~ ".ts"

    unreadable = %{working | sync: fn ^lsp, path -> {:error, {:file_read, path, :enoent}} end}

    assert %{"ok" => false, "error" => %{"code" => "file_unreadable"}} =
             Service.handle(unreadable, %{
               "op" => "refs",
               "path" => "/repo/a.ts",
               "line" => 3,
               "column" => 7
             })
  end

  test "status and stop are tagged control results on protocol 2" do
    assert {:daemon, :status, %{"ok" => true, "result" => status}} =
             Service.handle(untouchable(), %{"op" => "status"})

    assert %{"service" => "symd", "protocol" => 2, "state" => "running", "pid" => pid} = status
    assert String.to_integer(pid) > 0

    assert {:daemon, :stop,
            %{"ok" => true, "result" => %{"state" => "stopping", "protocol" => 2}}} =
             Service.handle(untouchable(), %{"op" => "stop"})
  end

  test "known failures have readable explanations" do
    for {reason, expected} <- [
          {:timeout, "Timed out"},
          {{:no_lsp_for_path, "/a.py", [".ts"]}, "no configured LSP handles /a.py"},
          {{:symbol_not_found, "parse", ["parser"]}, "the servers suggest: parser"},
          {{:executable_not_found, "tls"}, "executable not found: tls"},
          {{:server_exited, 127}, "exited with status 127"},
          {:lsp_timeout, "timed out waiting for the language server"},
          {{:lsp_error, -32601, "unhandled method"}, "unhandled method"},
          {{:file_read, "/x.ts", :enoent}, "no such file"}
        ] do
      assert Service.error("test_error", reason)["error"]["message"] =~ expected
    end
  end
end
