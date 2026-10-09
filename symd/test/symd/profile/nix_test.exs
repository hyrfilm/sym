defmodule Symd.Profile.NixTest do
  use ExUnit.Case, async: true

  alias Symd.Profile
  alias Symd.Profile.Nix

  @name "typescript-language-server"
  @installable "nixpkgs#typescript-language-server"
  # Contains a space on purpose: the path must stay one argv element.
  @location "/srv/sym profile"
  @profile "/srv/sym profile/profile"

  # A fake nix that records every invocation in the test's mailbox and answers
  # with `reply`, so tests can assert on the exact argv without running Nix.
  defp recording(reply) do
    fn executable, argv ->
      send(self(), {:run, executable, argv})
      reply
    end
  end

  # For tests where nix must not be called at all.
  defp never(_executable, _argv), do: flunk("unexpected command execution")

  @tag tmp_dir: true
  test "construction binds identity and command location without effects", %{tmp_dir: tmp_dir} do
    location = Path.join(tmp_dir, "symd-nix")
    profile = Nix.new("symd-nix", location, &never/2)

    assert profile.name == "symd-nix"
    assert profile.location == location
    refute File.exists?(location)

    assert Profile.command(profile, %{executable: @name, args: ["--stdio"]}) ==
             {Path.join(location, "profile/bin/#{@name}"), ["--stdio"]}
  end

  test "add and remove run nix against this profile with the name as one argument" do
    profile = Nix.new("symd-nix", @location, recording({"", 0}))

    assert Profile.add(profile, @name) == :ok
    assert_received {:run, "nix", ["profile", "add", "--profile", @profile, @installable]}

    assert Profile.remove(profile, @name) == :ok
    assert_received {:run, "nix", ["profile", "remove", "--profile", @profile, @name]}

    refute_received {:run, _, _}
  end

  # Names end up in argv and in paths, so anything flag-like, path-like, or with
  # shell metacharacters is refused before nix ever runs.
  test "invalid package names never reach the command runner" do
    profile = Nix.new("symd-nix", @location, &never/2)

    for name <- ["", "../bad", "-flag", "foo;bar", "two names", 42] do
      assert Profile.add(profile, name) == {:error, :invalid_package_name}
      assert Profile.remove(profile, name) == {:error, :invalid_package_name}
    end
  end

  @tag tmp_dir: true
  test "install creates an empty directory and leaves it alone on repeat", %{tmp_dir: tmp_dir} do
    location = Path.join(tmp_dir, "symd-nix")
    profile = Nix.new("symd-nix", location, &never/2)

    assert Profile.install(profile) == :ok
    assert File.ls!(location) == []

    File.write!(Path.join(location, "existing"), "keep me")
    assert Profile.install(profile) == :ok
    assert File.read!(Path.join(location, "existing")) == "keep me"
  end

  @tag tmp_dir: true
  test "install reports a filesystem failure without replacing an existing file", %{
    tmp_dir: tmp_dir
  } do
    location = Path.join(tmp_dir, "symd-nix")
    File.write!(location, "keep me")

    assert {:error, _reason} = Profile.install(Nix.new("symd-nix", location, &never/2))
    assert File.read!(location) == "keep me"
  end

  # Generation links point into the Nix store. Uninstall must delete the links,
  # not follow them, or it would wipe store paths.
  @tag tmp_dir: true
  test "uninstall removes the directory and its links but not their targets", %{tmp_dir: tmp_dir} do
    location = Path.join(tmp_dir, "symd-nix")
    store = Path.join(tmp_dir, "store-target")
    File.mkdir_p!(store)
    File.write!(Path.join(store, "package"), "keep me")
    profile = Nix.new("symd-nix", location, &never/2)
    :ok = Profile.install(profile)
    File.ln_s!(store, Path.join(location, "profile-1-link"))
    File.ln_s!("profile-1-link", Path.join(location, "profile"))

    assert Profile.uninstall(profile) == :ok
    assert File.lstat(location) == {:error, :enoent}
    assert File.read!(Path.join(store, "package")) == "keep me"
    assert Profile.uninstall(profile) == :ok
  end

  test "list asks nix for the JSON manifest and returns sorted names" do
    for {manifest, names} <- [
          {~s({"version":3,"elements":{}}), []},
          {~s({"version":3,"elements":{"typescript-language-server":{},"elixir-ls":{}}}),
           ["elixir-ls", "typescript-language-server"]}
        ] do
      profile = Nix.new("symd-nix", @location, recording({manifest, 0}))

      assert Profile.list(profile) == {:ok, names}
      assert_received {:run, "nix", ["profile", "list", "--profile", @profile, "--json"]}
    end
  end

  test "failed nix commands return their status and output" do
    profile = Nix.new("symd-nix", @location, fn _, _ -> {"Nix failed", 17} end)
    failure = {:error, {:command_failed, 17, "Nix failed"}}

    assert Profile.add(profile, @name) == failure
    assert Profile.remove(profile, @name) == failure
    assert Profile.list(profile) == failure
  end

  # An unreadable or unexpected manifest must not look like "nothing installed".
  test "invalid manifest output is an error, not an empty profile" do
    profile = Nix.new("symd-nix", @location, fn _, _ -> {"{", 0} end)
    assert {:error, {:invalid_profile_json, _reason}} = Profile.list(profile)

    for output <- ["{}", "[]", ~s({"version":3,"elements":[]}), ~s({"version":4,"elements":{}})] do
      profile = Nix.new("symd-nix", @location, fn _, _ -> {output, 0} end)
      assert Profile.list(profile) == {:error, :invalid_profile_manifest}
    end
  end

  # System.cmd raises when the executable can't be started; that must become a
  # value, not a crash.
  test "an unavailable nix executable returns a command start error" do
    profile = Nix.new("symd-nix", @location, fn _, _ -> raise ErlangError, original: :enoent end)

    assert Profile.add(profile, @name) == {:error, {:command_start_failed, :enoent}}
  end
end
