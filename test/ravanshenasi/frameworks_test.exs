defmodule Ravanshenasi.FrameworksTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.Frameworks

  test "default_frameworks devolve as 7 predefinidas" do
    names = Frameworks.default_frameworks() |> Enum.map(& &1.name)
    assert length(names) == 7
    assert "TCC" in names
  end

  test "admin cria framework de catálogo (user_id nil) e aparece na listagem" do
    scope = user_scope_fixture()
    assert {:ok, fw} = Frameworks.create_tenant_framework(scope, %{name: "Sistêmica", description: "..."})
    assert fw.user_id == nil
    assert "Sistêmica" in Enum.map(Frameworks.list_frameworks(scope), & &1.name)
  end

  test "therapist não cria framework de catálogo" do
    scope = therapist_scope_fixture()
    assert {:error, :unauthorized} = Frameworks.create_tenant_framework(scope, %{name: "X", description: "y"})
  end

  test "clinic-admin não cria framework próprio" do
    scope = clinic_admin_scope_fixture()
    assert {:error, :unauthorized} = Frameworks.create_own_framework(scope, %{name: "X", description: "y"})
  end

  test "list_frameworks faz união simples: catálogo do tenant + próprios do user, não de outro user" do
    admin = clinic_admin_scope_fixture()
    scope = therapist_scope_fixture(admin.tenant)
    other = therapist_scope_fixture(admin.tenant)

    {:ok, _cat} = Frameworks.create_tenant_framework(admin, %{name: "Catálogo Casa", description: "..."})
    {:ok, _own} = Frameworks.create_own_framework(scope, %{name: "Minha Linha", description: "..."})
    {:ok, _other_own} = Frameworks.create_own_framework(other, %{name: "Linha do Outro", description: "..."})

    names = Frameworks.list_frameworks(scope) |> Enum.map(& &1.name)
    assert "Catálogo Casa" in names      # herdado do tenant (user_id NULL)
    assert "Minha Linha" in names        # própria
    refute "Linha do Outro" in names     # própria do colega — invisível
  end
end
