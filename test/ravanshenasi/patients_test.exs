defmodule Ravanshenasi.PatientsTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.Patients

  test "create + list scoped por dono" do
    s = user_scope_fixture()
    assert {:ok, p} = Patients.create_patient(s, %{name: "Maria"})
    assert p.user_id == s.user.id and p.tenant_id == s.tenant.id
    assert [%{name: "Maria"}] = Patients.list_patients(s)
  end

  test "outro user do mesmo tenant (clínica) não vê o paciente" do
    admin = clinic_admin_scope_fixture()
    s = therapist_scope_fixture(admin.tenant)
    other = therapist_scope_fixture(admin.tenant)
    {:ok, p} = Patients.create_patient(s, %{name: "Maria"})

    assert Patients.list_patients(other) == []
    assert Patients.get_patient(other, p.id) == nil
  end

  test "busca por nome (ilike) e filtro por status" do
    s = user_scope_fixture()
    {:ok, _} = Patients.create_patient(s, %{name: "Ana Paula", status: :active})
    {:ok, _} = Patients.create_patient(s, %{name: "Bruno", status: :waitlist})

    assert [%{name: "Ana Paula"}] = Patients.list_patients(s, q: "ana")
    assert [%{name: "Bruno"}] = Patients.list_patients(s, status: :waitlist)
  end

  test "inactivate_patient faz soft-delete" do
    s = user_scope_fixture()
    {:ok, p} = Patients.create_patient(s, %{name: "Maria"})
    assert {:ok, p} = Patients.inactivate_patient(s, p)
    assert p.status == :inactive
    assert Patients.list_patients(s, status: :active) == []
  end

  test "admin de clínica não cria paciente" do
    s = clinic_admin_scope_fixture()
    assert {:error, :unauthorized} = Patients.create_patient(s, %{name: "X"})
  end
end
