defmodule Symd.ConfigTest do
  use ExUnit.Case, async: true

  alias Symd.Config

  # Values pass through untouched: the parser doesn't know what "future-backend"
  # means and doesn't expand "$HOME". Keys outside the three we need are ignored.
  test "extracts the profile fields and leaves everything else alone" do
    toml = """
    other = true
    [profile]
    name = "custom"
    type = "future-backend"
    location = '$HOME/custom'
    extra = true
    """

    assert Config.parse(toml) ==
             {:ok, %{name: "custom", type: "future-backend", location: "$HOME/custom"}}
  end

  test "reports missing fields and unexpected table shapes" do
    for toml <- [
          "",
          "profile = false",
          "[profile]\ntype = 'nix'\nlocation = '/srv/sym'",
          "[profile]\nname = 'symd-nix'\nlocation = '/srv/sym'",
          "[profile]\nname = 'symd-nix'\ntype = 'nix'"
        ] do
      assert Config.parse(toml) == {:error, "expected [profile] with name, type, and location"}
    end
  end

  # Both the syntax error and the duplicate key come from the TOML library. We
  # only care that they turn into a readable string, not what it says.
  test "reports malformed TOML as a readable error" do
    for toml <- ["[profile", "[profile]\ntype = 'nix'\ntype = 'npm'"] do
      assert {:error, "invalid TOML: " <> _} = Config.parse(toml)
    end
  end
end
