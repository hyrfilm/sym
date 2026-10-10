defmodule Symd.ConfigTest do
  use ExUnit.Case, async: true

  alias Symd.Config

  # Commands pass through untouched: resolving them against PATH or the config
  # directory happens later. Extensions are normalized to lower case, and the
  # entries come back sorted so extension lookups are deterministic.
  test "parses lsp tables, sorted by name, with args defaulting to empty" do
    toml = """
    other = true

    [lsp.typescript]
    command = "typescript-language-server"
    args = ["--stdio"]
    extensions = [".TS", ".tsx"]

    [lsp.elixir]
    command = "./bin/dexter"
    extensions = [".ex"]
    extra = true
    """

    assert Config.parse(toml) ==
             {:ok,
              [
                %{name: "elixir", command: "./bin/dexter", args: [], extensions: [".ex"]},
                %{
                  name: "typescript",
                  command: "typescript-language-server",
                  args: ["--stdio"],
                  extensions: [".ts", ".tsx"]
                }
              ]}
  end

  test "reports missing lsp tables" do
    for toml <- ["", "lsp = false", "other = 1"] do
      assert Config.parse(toml) ==
               {:error, "expected at least one [lsp.<name>] table with command and extensions"}
    end
  end

  test "reports broken entries by name" do
    assert Config.parse("[lsp.ts]\nextensions = ['.ts']") ==
             {:error, "[lsp.ts] needs a non-empty command string"}

    assert Config.parse("[lsp.ts]\ncommand = ''\nextensions = ['.ts']") ==
             {:error, "[lsp.ts] needs a non-empty command string"}

    assert Config.parse("[lsp.ts]\ncommand = 'x'\nargs = [1]\nextensions = ['.ts']") ==
             {:error, "[lsp.ts] args must be a list of strings"}

    for extensions <- ["extensions = []", "extensions = ['ts']", "extensions = 'ts'", ""] do
      assert Config.parse("[lsp.ts]\ncommand = 'x'\n" <> extensions) ==
               {:error, ~s([lsp.ts] extensions must be a non-empty list like [".ts", ".tsx"])}
    end
  end

  # Both the syntax error and the duplicate key come from the TOML library. We
  # only care that they turn into a readable string, not what it says.
  test "reports malformed TOML as a readable error" do
    for toml <- ["[lsp", "[lsp.ts]\ncommand = 'x'\ncommand = 'y'"] do
      assert {:error, "invalid TOML: " <> _} = Config.parse(toml)
    end
  end
end
