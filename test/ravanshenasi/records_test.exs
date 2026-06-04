defmodule Ravanshenasi.RecordsTest do
  use Ravanshenasi.DataCase, async: false

  import Ravanshenasi.AccountsFixtures
  alias Ravanshenasi.{Patients, Records, Sessions}

  setup do
    scope = user_scope_fixture()
    {:ok, patient} = Patients.create_patient(scope, %{name: "Maria"})
    {:ok, session} = Sessions.create_session(scope, patient, %{notes: "n"})
    {:ok, record} = insert_record(scope, session, patient)
    %{scope: scope, record: record}
  end

  test "mark_generating → complete grava content+model+done e faz broadcast", %{
    scope: s,
    record: r
  } do
    Records.subscribe(r.id)
    {:ok, r} = Records.mark_generating(s, r)
    assert r.generation_status == :generating
    {:ok, r} = Records.complete(s, r, "S:..\nO:..\nA:..\nP:..", "stub:stub-model")
    assert r.generation_status == :done and r.model_used == "stub:stub-model"
    assert_receive {:record_updated, %{generation_status: :done}}
  end

  test "retry_generation só de :error", %{scope: s, record: r} do
    {:ok, r} = Records.fail(s, r, "boom")
    assert r.generation_status == :error
    assert {:ok, r} = Records.retry_generation(s, r)
    assert r.generation_status == :pending
  end

  test "retry_generation em :done → {:error, :not_retryable}", %{scope: s, record: r} do
    {:ok, r} = Records.complete(s, r, "c", "m")
    assert {:error, :not_retryable} = Records.retry_generation(s, r)
  end

  test "list_records lista os prontuários do paciente do dono", %{scope: s, record: r} do
    records = Records.list_records(s, %{id: r.patient_id})
    assert Enum.any?(records, &(&1.id == r.id))
  end

  defp insert_record(scope, session, patient) do
    Ravanshenasi.Repo.transact_tenant(scope, fn ->
      %Ravanshenasi.Records.Record{
        tenant_id: scope.tenant.id,
        user_id: scope.user.id,
        session_id: session.id,
        patient_id: patient.id,
        generation_status: :pending
      }
      |> Ecto.Changeset.change()
      |> Ravanshenasi.Repo.insert()
    end)
  end
end
