defmodule Ravanshenasi.Patients.PatientTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Patients.Patient

  test "changeset válido" do
    cs = Patient.changeset(%Patient{}, %{name: "Maria", status: :active})
    assert cs.valid?
  end

  test "name obrigatório" do
    cs = Patient.changeset(%Patient{}, %{status: :active})
    refute cs.valid?
    assert %{name: ["can't be blank"]} = errors_on(cs)
  end

  test "status fora do enum é inválido" do
    cs = Patient.changeset(%Patient{}, %{name: "X", status: :deleted})
    refute cs.valid?
  end
end

defmodule Ravanshenasi.Patients.PatientFkTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.Patients.Patient
  alias Ravanshenasi.Repo

  test "FK composta rejeita paciente com user_id de OUTRO tenant" do
    a = user_scope_fixture()
    b = user_scope_fixture()

    # cria paciente no tenant A com dono do tenant B — via bypass (fura RLS),
    # então a defesa que resta é a FK composta (tenant_id, user_id).
    assert_raise Ecto.ConstraintError, fn ->
      Repo.with_registration_bypass(fn ->
        %Patient{tenant_id: a.tenant.id, user_id: b.user.id, name: "X"}
        |> Ecto.Changeset.change()
        |> Repo.insert!()
      end)
    end
  end
end
