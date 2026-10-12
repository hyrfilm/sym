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

  defp deps(workspace) do
    [fetch: fn _cwd -> {:ok, workspace} end, list: fn -> [] end]
  end

  defp untouched_deps do
    [
      fetch: fn cwd -> flunk("unexpected workspace lookup from #{inspect(cwd)}") end,
      list: fn -> flunk("unexpected workspace listing") end
    ]
  end

  test "invalid requests never resolve a workspace" do
    for json <- [
          "{",
          "null",
          ~s({"op":"unknown"}),
          ~s({"op":"symbols"}),
          ~s({"op":"symbols","path":"/f.ts"}),
          ~s({"op":"symbols","path":"","cwd":"/repo"}),
          ~s({"op":"symbols","path":"/f.ts","cwd":"/repo","extra":true}),
          ~s({"op":"def"}),
          ~s({"op":"def","name":"x"}),
          ~s({"op":"def","name":"","cwd":"/repo"}),
          ~s({"op":"refs","name":"x","path":"/f.ts","cwd":"/repo"}),
          ~s({"op":"def","path":"/f.ts","line":0,"column":1,"cwd":"/repo"}),
          ~s({"op":"refs","path":"/f.ts","line":"1","column":1,"cwd":"/repo"}),
          ~s({"op":"status","extra":true})
        ] do
      assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
               Service.request(json, untouched_deps())
    end
  end

  test "a relative cwd is rejected, not resolved against the daemon" do
    assert %{"ok" => false, "error" => %{"code" => "invalid_request", "message" => message}} =
             Service.handle(%{"op" => "def", "name" => "x", "cwd" => "repo"}, untouched_deps())

    assert message =~ "absolute"
  end

  test "semantic results and failures become reply envelopes with stable codes" do
    lsp = %{name: "ts", command: "x", args: [], extensions: [".ts"]}

    working = %{
      untouchable()
      | lsps: [lsp],
        sync: fn ^lsp, _path -> {:ok, ""} end,
        request: fn ^lsp, "textDocument/documentSymbol", _params -> {:ok, []} end
    }

    assert Service.handle(
             %{"op" => "symbols", "path" => "/repo/a.ts", "cwd" => "/repo"},
             deps(working)
           ) == %{"ok" => true, "result" => %{"symbols" => []}}

    assert %{"ok" => false, "error" => %{"code" => "unsupported_file", "message" => message}} =
             Service.handle(
               %{"op" => "symbols", "path" => "/repo/a.py", "cwd" => "/repo"},
               deps(working)
             )

    assert message =~ ".ts"

    unreadable = %{working | sync: fn ^lsp, path -> {:error, {:file_read, path, :enoent}} end}

    assert %{"ok" => false, "error" => %{"code" => "file_unreadable"}} =
             Service.handle(
               %{
                 "op" => "refs",
                 "path" => "/repo/a.ts",
                 "line" => 3,
                 "column" => 7,
                 "cwd" => "/repo"
               },
               deps(unreadable)
             )
  end

  test "workspace resolution failures use their own stable codes" do
    for {reason, code} <- [
          {{:no_workspace, "/somewhere"}, "no_workspace"},
          {{:no_config, "/repo", "/home/.config/sym/sym.toml"}, "no_config"},
          {{:config_unreadable, "/repo/sym.toml", :eacces}, "invalid_config"},
          {{:invalid_config, "/repo/sym.toml", "invalid TOML"}, "invalid_config"},
          {{:lsp_failed, "elixir", {:server_exited, 1}}, "lsp_unavailable"},
          {{:no_lsp_for_workspace, "/repo", [".ts"]}, "unsupported_workspace"}
        ] do
      deps = [fetch: fn _cwd -> {:error, reason} end]

      assert %{"ok" => false, "error" => %{"code" => ^code}} =
               Service.handle(%{"op" => "def", "name" => "x", "cwd" => "/repo"}, deps)
    end
  end

  test "status and stop are tagged control results on one protocol" do
    list = [%{"root" => "/repo", "config" => "/repo/sym.toml"}]

    assert {:daemon, :status, %{"ok" => true, "result" => status}} =
             Service.handle(%{"op" => "status"}, list: fn -> list end)

    assert %{
             "service" => "symd",
             "protocol" => protocol,
             "state" => "running",
             "pid" => pid,
             "workspaces" => ^list
           } = status

    assert String.to_integer(pid) > 0

    assert {:daemon, :stop,
            %{"ok" => true, "result" => %{"state" => "stopping", "protocol" => ^protocol}}} =
             Service.handle(%{"op" => "stop"}, untouched_deps())
  end

  test "known failures have readable explanations" do
    for {reason, expected} <- [
          {:timeout, "Timed out"},
          {{:no_workspace, "/deep/dir"}, "no sym.toml or .git"},
          {{:no_config, "/repo", "/cfg/sym/sym.toml"}, "no global config at /cfg/sym/sym.toml"},
          {{:invalid_config, "/repo/sym.toml", "invalid TOML: boom"}, "invalid TOML"},
          {{:config_unreadable, "/repo/sym.toml", :eacces}, "permission denied"},
          {{:no_lsp_for_path, "/a.py", [".ts"]}, "no configured LSP handles /a.py"},
          {{:no_lsp_for_workspace, "/repo", [".ts", ".ex"]},
           "no configured language server has matching files under /repo"},
          {{:symbol_not_found, "parse", ["parser"]}, "the servers suggest: parser"},
          {{:executable_not_found, "tls"}, "executable not found: tls"},
          {{:server_exited, 127}, "exited with status 127"},
          {{:lsp_failed, "elixir", {:server_exited, 1}}, "[elixir] the language server exited"},
          {:lsp_timeout, "timed out waiting for the language server"},
          {{:lsp_error, -32601, "unhandled method"}, "unhandled method"},
          {{:file_read, "/x.ts", :enoent}, "no such file"}
        ] do
      assert Service.error("test_error", reason)["error"]["message"] =~ expected
    end
  end
end
