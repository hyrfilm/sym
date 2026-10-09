defmodule Symd.Profile do
  @moduledoc """
  A profile is a name, a location, and the functions that manage its resources.

  The backend supplies those functions, so this module never needs to know
  which package manager is being used or what a resource looks like. These
  small delegates pass arguments and results through unchanged; tests can use
  ordinary closures in place of real commands.

  Resolving a command is separate from running it. `command/2` gives the caller
  an executable and argv, leaving process ownership to the runtime layer.
  """

  @enforce_keys [:add, :remove, :list, :command]
  defstruct [:name, :location, :install, :uninstall] ++ @enforce_keys

  @doc "Prepares the whole profile. The supplied operation should be safe to repeat."
  def install(%__MODULE__{install: operation}), do: operation.()

  @doc "Removes the whole profile. An already-absent profile should be a success."
  def uninstall(%__MODULE__{uninstall: operation}), do: operation.()

  @doc "Passes a resource to the configured add operation."
  def add(%__MODULE__{add: operation}, resource), do: operation.(resource)

  @doc "Removes one installed resource from the profile."
  def remove(%__MODULE__{remove: operation}, resource), do: operation.(resource)

  @doc "Returns what's installed in the profile, as the backend reports it."
  def list(%__MODULE__{list: operation}), do: operation.()

  @doc "Returns the executable and argv supplied by the configured operation."
  def command(%__MODULE__{command: operation}, resource), do: operation.(resource)
end
