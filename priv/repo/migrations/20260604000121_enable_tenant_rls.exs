defmodule Ravanshenasi.Repo.Migrations.EnableTenantRls do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    # Enforce RLS only where tenant isolation provides real defense in depth:
    # invitations now, and all clinical data (patients/sessions/records/audio)
    # in slices 1+, where every query is tenant-scoped.
    #
    # users/tenants stay out: they do not store clinical data and participate in
    # pre-tenant auth/settings flows (login, session, magic link, email/password
    # changes). They are protected by explicit query scoping plus a global unique
    # email. Enforcing RLS there would force roughly 8 own-user identity operations
    # to run under bypass, spreading bypass without proportional security value.
    enable_tenant_rls("invitations")
  end
end
