defmodule Ravanshenasi.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Ravanshenasi.Accounts` context.
  """

  import Ecto.Query

  alias Ravanshenasi.Accounts
  alias Ravanshenasi.Accounts.Scope
  alias Ravanshenasi.Accounts.User
  alias Ravanshenasi.Repo

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    %{email: email} = valid_user_attributes(attrs)

    {:ok, user} =
      Accounts.register_solo(%{name: "Test User", email: email, office_name: "Test Office"})

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} =
      Accounts.login_user_by_magic_link(token)

    user
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    tenant = Accounts.get_tenant!(user.tenant_id)
    Scope.for_user(user) |> Scope.put_tenant(tenant)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end

  @doc """
  Scope of a therapist invited into a CLINIC tenant. Invitations are clinic-only
  (require_clinic_admin), so when tenant is nil a fresh clinic is created. Pass a
  clinic tenant to put two therapists in the same one.
  """
  def therapist_scope_fixture(tenant \\ nil) do
    admin_scope =
      case tenant do
        nil -> clinic_admin_scope_fixture()
        t -> admin_scope_for(t)
      end

    email = "therapist#{System.unique_integer()}@example.com"

    {:ok, raw} =
      Accounts.create_invitation(admin_scope, %{email: email, role: :therapist})

    {:ok, user} =
      Accounts.accept_invitation(raw, %{
        name: "Therapist",
        password: "supersecret123"
      })

    user = Repo.with_auth_bypass(fn -> Repo.preload(user, :tenant) end)

    Scope.for_user(user)
    |> Scope.put_tenant(user.tenant)
  end

  @doc "Scope of a clinic admin (plan: :clinic), who manages but does not attend."
  def clinic_admin_scope_fixture do
    {:ok, user} =
      Accounts.register_clinic(%{
        clinic_name: "Clinic",
        name: "Admin",
        email: "admin#{System.unique_integer()}@example.com"
      })

    user = Repo.with_auth_bypass(fn -> Repo.preload(user, :tenant) end)

    Scope.for_user(user)
    |> Scope.put_tenant(user.tenant)
  end

  # Private: admin scope from an existing tenant (picks its first admin).
  defp admin_scope_for(tenant) do
    user =
      Repo.with_auth_bypass(fn ->
        Repo.one!(
          from u in User,
            where: u.tenant_id == ^tenant.id and u.role == :admin,
            limit: 1
        )
      end)

    Scope.for_user(user) |> Scope.put_tenant(tenant)
  end
end
