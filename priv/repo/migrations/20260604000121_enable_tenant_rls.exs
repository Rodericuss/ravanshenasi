defmodule Ravanshenasi.Repo.Migrations.EnableTenantRls do
  use Ecto.Migration
  import Ravanshenasi.RLS

  def change do
    # RLS forçado só onde o isolamento por tenant rende defesa em profundidade real:
    # invitations agora, e todo dado clínico (patients/sessions/records/audio) nas
    # fatias 1+, onde TODA query é tenant-scoped.
    #
    # users/tenants ficam FORA: não guardam dado clínico e participam de fluxos de
    # auth/settings pré-tenant (login, sessão, magic link, trocar email/senha). São
    # protegidos por scope explícito nas queries + email único global. Forçar RLS
    # neles obrigaria ~8 operações de identidade-do-próprio-user a rodar sob bypass,
    # espalhando o bypass sem ganho de segurança proporcional.
    enable_tenant_rls("invitations")
  end
end
