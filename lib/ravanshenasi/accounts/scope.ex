defmodule Ravanshenasi.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Ravanshenasi.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias Ravanshenasi.Accounts.{Tenant, User}

  defstruct user: nil, tenant: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc "Attaches a tenant to an existing scope."
  def put_tenant(%__MODULE__{} = scope, %Tenant{} = tenant) do
    %{scope | tenant: tenant}
  end

  @doc "Returns true if the scope's user has the :admin role."
  def admin?(%__MODULE__{user: %{role: :admin}}), do: true
  def admin?(_), do: false

  @doc "Returns true if the scope's user has the :therapist role."
  def therapist?(%__MODULE__{user: %{role: :therapist}}), do: true
  def therapist?(_), do: false

  @doc """
  True if the scope's user provides clinical care (sees patients):
  a therapist, or the admin of a solo tenant. A clinic admin does not.
  """
  def clinical_access?(%__MODULE__{user: %{role: :therapist}}), do: true
  def clinical_access?(%__MODULE__{user: %{role: :admin}, tenant: %{plan: :solo}}), do: true
  def clinical_access?(_), do: false

  @doc """
  Returns true only for an :admin whose tenant is on the :clinic plan.

  Member management (invites, listing, removal) belongs to clinic admins only —
  a solo admin manages a single-seat tenant and has no one to invite (spec §5.3/§6).
  """
  def clinic_admin?(%__MODULE__{user: %{role: :admin}, tenant: %{plan: :clinic}}), do: true
  def clinic_admin?(_), do: false
end
