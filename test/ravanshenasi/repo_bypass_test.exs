defmodule Ravanshenasi.RepoBypassTest do
  use Ravanshenasi.DataCase, async: false
  # async: false proposital: este teste exercita transact_tenant/with_*_bypass
  # (transaction + SET LOCAL). Sob o Ecto Sandbox concorrente isso tem race; em
  # produção cada request usa tx curta isolada, sem o problema. Serializado de propósito.

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
