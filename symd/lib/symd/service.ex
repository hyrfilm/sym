defmodule Symd.Service do
  @moduledoc """
  Connects client requests to the configured profile.

  Startup turns the parsed config into a working profile. After that, both
  transports send their requests here, so add/list behave the same over a
  socket and over stdin/stdout. Replies contain either a result or an error;
  the CLI can print them without knowing which backend did the work.
  """

  alias Symd.{Config, Profile}

  @doc """
  Reads the config, builds its profile, and gets that profile ready to use.
  For Nix this creates an empty directory, not any packages. The injected
  runner is passed to the backend so startup and dispatch can be tested
  without a real package manager.
  """
  def open(config_path, run \\ &System.cmd/2) do
    with {:ok, toml} <- File.read(config_path),
         {:ok, config} <- Config.parse(toml),
         {:ok, profile} <- build_profile(config, config_path, run),
         :ok <- Profile.install(profile) do
      {:ok, profile}
    end
  end

  @doc """
  Decodes a request and passes it to `handle/2`. Bad JSON becomes an error
  reply so it only spoils that request. Transport owns framing and size limits;
  this function deals with the contents of a request.
  """
  def request(profile, json) do
    case JSON.decode(json) do
      {:ok, request} -> handle(profile, request)
      {:error, _reason} -> error("invalid_request", "expected a JSON request")
    end
  end

  @doc """
  Handles the decoded add/list messages in our small public protocol.
  We reject missing and extra fields so a misspelled option can't silently
  change what a request does. Package-name rules stay with the backend.
  """
  def handle(profile, %{"op" => "add", "lsp" => name} = request)
      when map_size(request) == 2 and is_binary(name) and byte_size(name) > 0 do
    case Profile.add(profile, name) do
      :ok -> %{"ok" => true, "result" => %{"lsp" => name}}
      {:error, reason} -> error("package_install_failed", reason)
    end
  end

  def handle(profile, %{"op" => "list"} = request) when map_size(request) == 1 do
    case Profile.list(profile) do
      {:ok, names} -> %{"ok" => true, "result" => %{"lsps" => names}}
      {:error, reason} -> error("package_list_failed", reason)
    end
  end

  def handle(_profile, _request),
    do: error("invalid_request", "expected add with lsp, or list")

  @doc """
  Builds the error half of a reply. Clients can use the stable `code`, while
  the message gives a person enough context to understand the failure.
  """
  def error(code, reason) do
    %{"ok" => false, "error" => %{"code" => code, "message" => message(reason)}}
  end

  # Nix usually writes diagnostics to stderr, which belongs to the daemon's
  # terminal. Don't claim there is an explanation in an empty stdout result.
  defp message({:command_failed, status, ""}),
    do: "nix exited with status #{status}; see symd stderr for diagnostics"

  defp message({:command_failed, status, output}),
    do: "nix exited with status #{status}: #{String.trim(output)}"

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)

  defp build_profile(%{type: "nix", name: name, location: location}, config_path, run)
       when is_binary(name) and byte_size(name) > 0 and is_binary(location) and
              byte_size(location) > 0 do
    # A config file should refer to the same directory wherever symd is started.
    location = Path.expand(location, Path.dirname(Path.expand(config_path)))
    {:ok, Profile.Nix.new(name, location, run)}
  end

  # Supporting another backend means adding its builder here. Parsing remains
  # generic; only this construction step needs to know which types we support.
  defp build_profile(config, _path, _run), do: {:error, {:unsupported_profile, config}}
end
