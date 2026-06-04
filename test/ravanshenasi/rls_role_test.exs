defmodule Ravanshenasi.RlsRoleTest do
  use Ravanshenasi.DataCase, async: true

  test "role de conexão da app não é superuser nem tem BYPASSRLS" do
    %{rows: [[is_super, is_bypass]]} =
      Ravanshenasi.Repo.query!(
        "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
      )

    assert is_super == false, "role da app é superuser — RLS seria ignorado"
    assert is_bypass == false, "role da app tem BYPASSRLS — RLS seria ignorado"
  end
end
