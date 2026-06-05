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

  test "count_active + list_recent: só ativos do dono, recentes primeiro" do
    s = user_scope_fixture()
    {:ok, p1} = Patients.create_patient(s, %{name: "Ana"})
    {:ok, p2} = Patients.create_patient(s, %{name: "Bia"})
    {:ok, inativo} = Patients.create_patient(s, %{name: "Cida"})
    {:ok, _} = Patients.inactivate_patient(s, inativo)
    # força p1 no passado (utc_datetime pode empatar entre os inserts) pra Bia vir primeiro
    Ravanshenasi.Repo.transact_tenant(s, fn ->
      Ravanshenasi.Repo.update_all(
        Ecto.Query.from(x in Ravanshenasi.Patients.Patient, where: x.id == ^p1.id),
        set: [inserted_at: ~U[2020-01-01 00:00:00Z]]
      )
    end)

    assert Patients.count_active(s) == 2
    recents = Patients.list_recent(s)
    assert hd(recents).id == p2.id
    refute Enum.any?(recents, &(&1.id == inativo.id))
  end

  test "count_active/list_recent não vazam pra outro profissional" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, _} = Patients.create_patient(a, %{name: "PA"})

    assert Patients.count_active(a) == 1
    assert Patients.count_active(b) == 0
    assert Patients.list_recent(b) == []
  end
end
