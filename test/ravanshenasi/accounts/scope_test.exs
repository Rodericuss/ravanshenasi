defmodule Ravanshenasi.Accounts.ScopeTest do
  use ExUnit.Case, async: true

  alias Ravanshenasi.Accounts.{Scope, Tenant, User}

  test "put_tenant + admin?/therapist?" do
    user = %User{role: :admin}
    tenant = %Tenant{id: Ecto.UUID.generate()}

    scope = Scope.for_user(user) |> Scope.put_tenant(tenant)

    assert scope.tenant == tenant
    assert Scope.admin?(scope)
    refute Scope.therapist?(scope)
  end

  test "therapist?" do
    scope = Scope.for_user(%User{role: :therapist})
    assert Scope.therapist?(scope)
    refute Scope.admin?(scope)
  end
end
