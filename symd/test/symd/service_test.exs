defmodule Symd.ServiceTest do
  use ExUnit.Case, async: true

  alias Symd.{Profile, Service}

  # The relative location in sym.toml resolves against the config file, not the
  # current directory, so symd behaves the same wherever it's started from.
  @tag tmp_dir: true
  test "startup creates the configured profile and add routes names through it", %{tmp_dir: dir} do
    config = Path.join(dir, "sym.toml")

    File.write!(config, """
    [profile]
    name = "symd-nix"
    type = "nix"
    location = "profiles/symd-nix"
    """)

    runner = fn executable, argv ->
      send(self(), {executable, argv})
      {"", 0}
    end

    assert {:ok, profile} = Service.open(config, runner)
    assert profile.name == "symd-nix"
    assert File.ls!(profile.location) == []
    refute_received {"nix", _}

    assert Service.handle(profile, %{"op" => "add", "lsp" => "dexter"}) ==
             %{"ok" => true, "result" => %{"lsp" => "dexter"}}

    assert_received {"nix", ["profile", "add", "--profile", path, "nixpkgs#dexter"]}
    assert path == Path.join(dir, "profiles/symd-nix/profile")
  end

  test "listing and package failures produce reply envelopes" do
    profile = %Profile{
      add: fn "missing" -> {:error, "missing package"} end,
      list: fn -> {:ok, ["dexter"]} end,
      remove: fn _ -> flunk("unexpected remove") end,
      command: fn _ -> flunk("unexpected command") end
    }

    assert Service.handle(profile, %{"op" => "list"}) ==
             %{"ok" => true, "result" => %{"lsps" => ["dexter"]}}

    assert %{
             "ok" => false,
             "error" => %{"code" => "package_install_failed", "message" => message}
           } =
             Service.handle(profile, %{"op" => "add", "lsp" => "missing"})

    assert message =~ "missing package"
  end

  test "invalid requests never run package commands" do
    profile = %Profile{
      add: fn _ -> flunk("unexpected add") end,
      list: fn -> flunk("unexpected list") end,
      remove: fn _ -> flunk("unexpected remove") end,
      command: fn _ -> flunk("unexpected command") end
    }

    for json <- [
          "{",
          "null",
          ~s({"op":"unknown"}),
          ~s({"op":"add"}),
          ~s({"op":"add","lsp":42}),
          ~s({"op":"list","extra":true})
        ] do
      assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} =
               Service.request(profile, json)
    end
  end

  @tag tmp_dir: true
  test "backend selection rejects unsupported configuration without creating a profile", %{
    tmp_dir: dir
  } do
    config = Path.join(dir, "sym.toml")
    location = Path.join(dir, "profile")
    runner = fn _, _ -> flunk("unexpected command") end

    File.write!(config, """
    [profile]
    name = "custom"
    type = "future-backend"
    location = "#{location}"
    """)

    assert {:error, {:unsupported_profile, %{type: "future-backend"}}} =
             Service.open(config, runner)

    refute File.exists?(location)
  end
end
