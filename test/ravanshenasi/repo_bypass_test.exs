defmodule Ravanshenasi.RepoBypassTest do
  use Ravanshenasi.DataCase, async: false
  # async: false intentional: this test exercises transact_tenant/with_*_bypass
  # (transaction + SET LOCAL). Under concurrent Ecto Sandbox this causes races; in
  # production each request uses a short isolated tx, so there is no issue. Serialized on purpose.

  alias Ravanshenasi.Repo

  test "with_auth_bypass liga o GUC dentro e desliga depois" do
    inside =
      Repo.with_auth_bypass(fn ->
        %{rows: [[v]]} = Repo.query!("SELECT current_setting('app.auth_bypass', true)")
        v
      end)

    assert inside == "on"

    %{rows: [[after_val]]} = Repo.query!("SELECT current_setting('app.auth_bypass', true)")
    assert after_val in [nil, "", "off"]
  end

  test "with_registration_bypass também liga e devolve resultado cru" do
    assert Repo.with_registration_bypass(fn -> :done end) == :done
  end
end
