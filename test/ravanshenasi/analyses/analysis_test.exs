defmodule Ravanshenasi.Analyses.AnalysisTest do
  use ExUnit.Case, async: true
  alias Ravanshenasi.Analyses.Analysis

  test "insert_changeset exige tenant/user/patient e nasce pending" do
    cs =
      Analysis.insert_changeset(%{
        tenant_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        patient_id: Ecto.UUID.generate()
      })

    assert cs.valid?
    assert Ecto.Changeset.apply_changes(cs).generation_status == :pending
  end

  test "insert_changeset inválido sem patient_id" do
    cs =
      Analysis.insert_changeset(%{tenant_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate()})

    refute cs.valid?
  end

  test "status_changeset altera generation_status/model/erro" do
    cs = Analysis.status_changeset(%Analysis{}, %{generation_status: :done, model_used: "stub:m"})
    assert Ecto.Changeset.apply_changes(cs).generation_status == :done
  end
end
