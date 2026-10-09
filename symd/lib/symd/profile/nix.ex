defmodule Symd.Profile.Nix do
  @moduledoc """
  Builds a profile backed by Nix at `<location>/profile`.

  The owned directory contains the profile and generation links. Installing it
  creates an empty directory; uninstalling it removes the links, leaving the
  Nix store untouched. Package names map to `nixpkgs#name`, and Nix remains the
  authority on installed resources.

  The injected runner accepts executable and argv and returns `{output, status}`,
  like `System.cmd/2`. Diagnostics stay on stderr so list output remains JSON.
  """

  alias Symd.Profile

  @doc """
  Puts together the profile's operations without running any of them yet.
  `run` defaults to `System.cmd/2`; tests supply a function with the same
  `{output, status}` result so they can check commands without invoking Nix.
  """
  def new(name, location, run \\ &System.cmd/2) do
    path = Path.join(location, "profile")
    # Every command targets our profile explicitly, never the user's default.
    # Keeping argv separate also leaves spaces in the path as ordinary data.
    nix = fn verb, args -> execute(run, ["profile", verb, "--profile", path | args]) end

    %Profile{
      name: name,
      location: location,
      # Nix creates its profile on the first add. Startup only needs the parent
      # directory, and mkdir_p leaves any existing packages alone.
      install: fn -> File.mkdir_p(location) end,
      uninstall: fn ->
        case File.rm_rf(location) do
          {:ok, _removed} -> :ok
          {:error, reason, file} -> {:error, {reason, file}}
        end
      end,
      add: fn name ->
        # Validate before interpolation too: invalid data should return an
        # error, not raise while being converted into an installable string.
        with :ok <- validate_name(name),
             {:ok, _output} <- nix.("add", ["nixpkgs##{name}"]),
             do: :ok
      end,
      remove: fn name ->
        with :ok <- validate_name(name), {:ok, _output} <- nix.("remove", [name]), do: :ok
      end,
      list: fn -> with {:ok, output} <- nix.("list", ["--json"]), do: decode_list(output) end,
      command: fn resource -> {Path.join([path, "bin", resource.executable]), resource.args} end
    }
  end

  defp validate_name(name) do
    # These names become Nix selectors. Reject paths and leading option flags;
    # the CLI itself doesn't need to know this backend's naming rules.
    if is_binary(name) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.+-]*\z/, name),
      do: :ok,
      else: {:error, :invalid_package_name}
  end

  defp execute(run, argv) do
    case run.("nix", argv) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:command_failed, status, output}}
    end
  rescue
    # A missing executable raises instead of returning an exit status. Keep it
    # in the same error flow so a failed install doesn't take down the daemon.
    error in ErlangError -> {:error, {:command_start_failed, error.original}}
  end

  defp decode_list(output) do
    # A changed or broken manifest isn't an empty profile. Report it rather
    # than silently telling the caller that nothing is installed.
    case JSON.decode(output) do
      {:ok, %{"version" => 3, "elements" => elements}} when is_map(elements) ->
        {:ok, elements |> Map.keys() |> Enum.sort()}

      {:ok, _other} ->
        {:error, :invalid_profile_manifest}

      {:error, reason} ->
        {:error, {:invalid_profile_json, reason}}
    end
  end
end
