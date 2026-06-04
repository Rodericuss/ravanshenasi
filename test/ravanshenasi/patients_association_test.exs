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
end
