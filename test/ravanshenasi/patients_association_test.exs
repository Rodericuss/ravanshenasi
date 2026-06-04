defmodule Ravanshenasi.PatientsAssociationTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.{Frameworks, Patients}

  setup do
    s = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(s, %{name: "Maria"})
    catalog = Frameworks.list_frameworks(s) |> hd()
    %{scope: s, patient: patient, framework: catalog}
  end

  test "activate/deactivate por presença na join", %{scope: s, patient: p, framework: f} do
    assert :ok = Patients.activate_framework(s, p, f)
    assert [%{id: id}] = Patients.list_patient_frameworks(s, p)
    assert id == f.id

    assert :ok = Patients.deactivate_framework(s, p, f)
    assert Patients.list_patient_frameworks(s, p) == []
  end

  test "não associa framework não-visível (de outro profissional)", %{scope: s, patient: p} do
    other = user_scope_fixture()
    {:ok, foreign} = Frameworks.create_own_framework(other, %{name: "Alheio", description: "x"})
    assert {:error, :not_found} = Patients.activate_framework(s, p, foreign)
  end

  test "list_patient_frameworks não vaza para outro therapist do mesmo tenant" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, patient_a} = Patients.create_patient(a, %{name: "Paciente de A"})

    {:ok, fw_a} =
      Frameworks.create_own_framework(a, %{name: "Linha Secreta de A", description: "x"})

    :ok = Patients.activate_framework(a, patient_a, fw_a)

    # B passa o struct do paciente de A — não pode enxergar os frameworks de A
    assert Patients.list_patient_frameworks(b, patient_a) == []
  end

  test "activate_framework rejeita catálogo de OUTRO tenant com :not_found", %{
    scope: s,
    patient: p
  } do
    other_tenant = user_scope_fixture()
    foreign_catalog = Frameworks.list_frameworks(other_tenant) |> Enum.find(&is_nil(&1.user_id))
    assert {:error, :not_found} = Patients.activate_framework(s, p, foreign_catalog)
  end
end
