defmodule Ravanshenasi.Accounts.ScopeClinicalAccessTest do
  use ExUnit.Case, async: true

  alias Ravanshenasi.Accounts.{Scope, Tenant, User}

  defp scope(role, plan) do
    %Scope{user: %User{role: role}, tenant: %Tenant{plan: plan}}
  end

  test "therapist tem acesso clínico em qualquer plano" do
    assert Scope.clinical_access?(scope(:therapist, :clinic))
    assert Scope.clinical_access?(scope(:therapist, :solo))
  end

  test "solo-admin tem acesso clínico; admin de clínica não" do
    assert Scope.clinical_access?(scope(:admin, :solo))
    refute Scope.clinical_access?(scope(:admin, :clinic))
  end

  test "scope sem user não tem acesso" do
    refute Scope.clinical_access?(%Scope{user: nil, tenant: nil})
  end
end
