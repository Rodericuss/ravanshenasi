defmodule Ravanshenasi.Accounts.InvitationTest do
  use Ravanshenasi.DataCase, async: true

  alias Ravanshenasi.Accounts.Invitation

  test "build/2 gera token cru + hash e expires_at futuro" do
    tenant_id = Ecto.UUID.generate()
    inviter_id = Ecto.UUID.generate()

    {raw_token, changeset} =
      Invitation.build(%{email: "novo@ex.com", role: :therapist}, tenant_id: tenant_id, invited_by_user_id: inviter_id)

    assert is_binary(raw_token) and byte_size(raw_token) > 20
    assert changeset.valid?
    assert get_field(changeset, :tenant_id) == tenant_id
    assert get_field(changeset, :token) != raw_token
    assert DateTime.compare(get_field(changeset, :expires_at), DateTime.utc_now()) == :gt
  end

  test "changeset exige email" do
    cs = Invitation.changeset(%Invitation{}, %{role: :therapist})
    refute cs.valid?
    assert %{email: ["can't be blank"]} = errors_on(cs)
  end
end
