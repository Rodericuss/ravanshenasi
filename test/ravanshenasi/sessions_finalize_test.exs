defmodule Ravanshenasi.SessionsFinalizeTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Patients, Sessions}
  alias Ravanshenasi.Records.GenerateSoapWorker

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    {:ok, session} = Sessions.create_session(scope, patient, %{notes: "n"})
    %{scope: scope, session: session}
  end

  test "finaliza + cria record pending + enfileira job", %{scope: s, session: sess} do
    assert {:ok, %{session: fsess, record: rec}} = Sessions.finalize_session(s, sess)
    assert fsess.status == :finalized
    assert rec.generation_status == :pending
    assert_enqueued(worker: GenerateSoapWorker, args: %{record_id: rec.id})
  end

  test "finalizar 2x → {:error, :already_finalized} sem segundo job", %{scope: s, session: sess} do
    {:ok, _} = Sessions.finalize_session(s, sess)
    again = Sessions.get_session!(s, sess.id)
    assert {:error, :already_finalized} = Sessions.finalize_session(s, again)
    assert [_one] = all_enqueued(worker: GenerateSoapWorker)
  end

  test "finalizar sessão de OUTRO profissional do mesmo tenant → :unauthorized (não :already_finalized)" do
    admin = clinic_admin_scope_fixture()
    a = therapist_scope_fixture(admin.tenant)
    b = therapist_scope_fixture(admin.tenant)
    {:ok, pa} = Patients.create_patient(a, %{name: "PA"})
    {:ok, sess} = Sessions.create_session(a, pa, %{notes: "n"})

    assert {:error, :unauthorized} = Sessions.finalize_session(b, sess)
    assert [] = all_enqueued(worker: GenerateSoapWorker)
  end
end
