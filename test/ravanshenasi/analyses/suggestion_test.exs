defmodule Ravanshenasi.Analyses.SuggestionTest do
  use ExUnit.Case, async: true
  alias Ravanshenasi.Analyses.Suggestion

  test "insert_changeset monta os campos e nasce suggested" do
    cs =
      Suggestion.insert_changeset(%{
        tenant_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        analysis_id: Ecto.UUID.generate(),
        framework_name: "TCC",
        justification: "j",
        techniques: ["t1", "t2"],
        watch_out: "w"
      })

    assert cs.valid?
    applied = Ecto.Changeset.apply_changes(cs)
    assert applied.status == :suggested
    assert applied.techniques == ["t1", "t2"]
  end

  test "status_changeset muda status" do
    cs = Suggestion.status_changeset(%Suggestion{}, %{status: :saved})
    assert Ecto.Changeset.apply_changes(cs).status == :saved
  end
end
