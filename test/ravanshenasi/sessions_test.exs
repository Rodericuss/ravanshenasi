defmodule Ravanshenasi.SessionsTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures

  alias Ravanshenasi.{Patients, Sessions}
  alias Ravanshenasi.Sessions.Session

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    %{scope: scope, patient: patient}
  end

  test "create + list scoped", %{scope: s, patient: p} do
    assert {:ok, sess} = Sessions.create_session(s, p, %{notes: "n1"})
    assert sess.status == :draft and sess.user_id == s.user.id and sess.patient_id == p.id
    assert [%{notes: "n1"}] = Sessions.list_sessions(s, p)
  end

  test "update bloqueado quando finalized", %{scope: s, patient: p} do
    {:ok, sess} = Sessions.create_session(s, p, %{notes: "n"})
    finalize!(s, sess)
    sess = Sessions.get_session!(s, sess.id)
    assert {:error, :finalized} = Sessions.update_session(s, sess, %{notes: "novo"})
  end

  test "outro profissional do mesmo tenant não vê", %{} do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})
    {:ok, _} = Sessions.create_session(a, pa, %{notes: "secreto"})
    assert Sessions.list_sessions(b, pa) == []
  end

  test "admin de clínica não cria sessão", %{patient: p} do
    admin = clinic_admin_scope_fixture()
    assert {:error, :unauthorized} = Sessions.create_session(admin, p, %{notes: "x"})
  end

  test "recent_finalized exclui a sessão informada", %{scope: s, patient: p} do
    {:ok, s1} = Sessions.create_session(s, p, %{notes: "antiga", date: ~U[2026-05-01 10:00:00Z]})
    {:ok, s2} = Sessions.create_session(s, p, %{notes: "atual", date: ~U[2026-06-01 10:00:00Z]})
    finalize!(s, s1)
    finalize!(s, s2)
    names = Sessions.recent_finalized(s, p, s2.id) |> Enum.map(& &1.notes)
    assert "antiga" in names
    refute "atual" in names
  end

  test "get_session_for_patient valida o paciente da rota", %{scope: s, patient: p} do
    {:ok, sess} = Sessions.create_session(s, p, %{notes: "n"})
    {:ok, other_p} = Patients.create_patient(s, %{name: "Outro"})
    assert %Session{} = Sessions.get_session_for_patient(s, p, sess.id)
    assert Sessions.get_session_for_patient(s, other_p, sess.id) == nil
  end

  defp finalize!(scope, sess) do
    Ravanshenasi.Repo.transact_tenant(scope, fn ->
      Ravanshenasi.Repo.update_all(
        from(x in Ravanshenasi.Sessions.Session, where: x.id == ^sess.id),
        set: [status: :finalized]
      )
    end)
  end
end
