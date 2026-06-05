defmodule RavanshenasiWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use RavanshenasiWeb, :html

  embed_templates "page_html/*"

  @doc "A feature card used on the landing page."
  attr :icon, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  def feature_card(assigns) do
    ~H"""
    <div class="group rounded-xl border bg-card p-6 text-card-foreground shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
      <div class="flex size-11 items-center justify-center rounded-lg bg-primary/10 text-primary transition group-hover:bg-primary group-hover:text-primary-foreground">
        <.icon name={@icon} class="size-6" />
      </div>
      <h3 class="mt-4 text-base font-semibold">{@title}</h3>
      <p class="mt-1.5 text-sm text-muted-foreground">{render_slot(@inner_block)}</p>
    </div>
    """
  end
end
