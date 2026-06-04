defmodule Ravanshenasi.ClinicalIsolationTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.{Patients, Repo}
  alias Ravanshenasi.Patients.Patient

  test "paciente do user A é invisível pro user B do MESMO tenant clínica (scope user_id)" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, _} = Patients.create_patient(a, %{name: "Sigiloso"})

    assert Patients.list_patients(b) == []
  end

  test "RLS fail-closed: sem GUC de tenant, query direta retorna 0 linhas" do
    a = user_scope_fixture()
    {:ok, _} = Patients.create_patient(a, %{name: "Sigiloso"})

    # nenhum transact_tenant ativo → app.current_tenant_id vazio → fail-closed
    assert Repo.all(Patient) == []
  end

  test "tenant B não enxerga paciente do tenant A (RLS tenant_id)" do
    a = user_scope_fixture()
    b = user_scope_fixture()
    {:ok, _} = Patients.create_patient(a, %{name: "Sigiloso"})

    assert Patients.list_patients(b) == []
  end
end
