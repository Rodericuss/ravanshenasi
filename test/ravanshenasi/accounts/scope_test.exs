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

  test "clinic_admin? só para admin de tenant clinic" do
    admin = %User{role: :admin}
    clinic = %Tenant{id: Ecto.UUID.generate(), plan: :clinic}
    solo = %Tenant{id: Ecto.UUID.generate(), plan: :solo}

    assert Scope.clinic_admin?(Scope.for_user(admin) |> Scope.put_tenant(clinic))
    refute Scope.clinic_admin?(Scope.for_user(admin) |> Scope.put_tenant(solo))

    refute Scope.clinic_admin?(
             Scope.for_user(%User{role: :therapist})
             |> Scope.put_tenant(clinic)
           )

    refute Scope.clinic_admin?(Scope.for_user(admin))
  end
end
