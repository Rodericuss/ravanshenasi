defmodule Ravanshenasi.Sessions.SessionTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Sessions.Session

  test "changeset válido" do
    cs =
      Session.changeset(%Session{}, %{date: ~U[2026-06-04 10:00:00Z], notes: "x", status: :draft})

    assert cs.valid?
  end

  test "status fora do enum é inválido" do
    cs = Session.changeset(%Session{}, %{status: :archived})
    refute cs.valid?
  end
end
