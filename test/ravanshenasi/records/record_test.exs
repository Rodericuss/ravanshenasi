defmodule Ravanshenasi.Records.RecordTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Records.Record

  test "content_changeset valida content" do
    cs = Record.content_changeset(%Record{}, %{content: "S:..\nO:..\nA:..\nP:.."})
    assert cs.valid?
  end

  test "status enum inválido" do
    cs = Record.status_changeset(%Record{}, %{generation_status: :weird})
    refute cs.valid?
  end
end
