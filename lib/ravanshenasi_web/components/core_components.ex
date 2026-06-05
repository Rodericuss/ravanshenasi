defmodule RavanshenasiWeb.CoreComponents do
  @moduledoc """
  Core UI components for PsiCare.

  Styling foundation: Tailwind CSS v4 with semantic design tokens
  (`bg-card`, `text-foreground`, `border-border`, `bg-primary`, …) inspired by
  Metronic 9. Icons come from Heroicons (see `icon/1`).
  """
  use Phoenix.Component
  use Gettext, backend: RavanshenasiWeb.Gettext

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed top-20 right-4 z-50 w-80 sm:w-96"
      {@rest}
    >
      <div class={[
        "flex items-start gap-3 rounded-lg border bg-card p-4 text-card-foreground shadow-lg cursor-pointer",
        @kind == :info && "border-l-4 border-l-info",
        @kind == :error && "border-l-4 border-l-destructive"
      ]}>
        <.icon
          :if={@kind == :info}
          name="hero-information-circle"
          class="size-5 shrink-0 text-info"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="size-5 shrink-0 text-destructive"
        />
        <div class="min-w-0 flex-1">
          <p :if={@title} class="text-sm font-semibold">{@title}</p>
          <p class="text-sm text-muted-foreground break-words">{msg}</p>
        </div>
        <button type="button" class="group shrink-0 cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-4 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button (or link styled as a button).

  ## Examples

      <.button>Send!</.button>
      <.button variant="outline" phx-click="go">Cancel</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any, default: nil

  attr :variant, :string,
    default: nil,
    values: [nil | ~w(primary secondary outline ghost destructive)]

  slot :inner_block, required: true

  @button_base "inline-flex items-center justify-center gap-1.5 rounded-md text-sm font-medium whitespace-nowrap transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background disabled:opacity-50 disabled:pointer-events-none h-9 px-4 py-2 cursor-pointer"

  def button(%{rest: rest} = assigns) do
    variants = %{
      nil => "bg-primary text-primary-foreground shadow-sm hover:bg-primary/90",
      "primary" => "bg-primary text-primary-foreground shadow-sm hover:bg-primary/90",
      "secondary" => "bg-secondary text-secondary-foreground shadow-sm hover:bg-secondary/80",
      "outline" =>
        "border border-input bg-background shadow-sm hover:bg-accent hover:text-accent-foreground",
      "ghost" => "hover:bg-accent hover:text-accent-foreground",
      "destructive" =>
        "bg-destructive text-destructive-foreground shadow-sm hover:bg-destructive/90"
    }

    assigns =
      assign(assigns, :computed_class, [
        @button_base,
        Map.fetch!(variants, assigns.variant),
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@computed_class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@computed_class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders a card container.

  ## Examples

      <.card>
        <:title>Patients</:title>
        content
      </.card>
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :title
  slot :actions
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["rounded-lg border bg-card text-card-foreground shadow-sm", @class]} {@rest}>
      <div
        :if={@title != [] or @actions != []}
        class="flex items-center justify-between gap-4 border-b px-5 py-4"
      >
        <h3 class="text-sm font-semibold">{render_slot(@title)}</h3>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>
      <div class="p-5">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  Renders a small status badge.

  ## Examples

      <.badge variant="success">done</.badge>
  """
  attr :variant, :string,
    default: "secondary",
    values: ~w(primary secondary success warning destructive info outline)

  attr :class, :any, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    variants = %{
      "primary" => "bg-primary/10 text-primary",
      "secondary" => "bg-secondary text-secondary-foreground",
      "success" => "bg-success/10 text-success",
      "warning" => "bg-warning/15 text-warning-foreground",
      "destructive" => "bg-destructive/10 text-destructive",
      "info" => "bg-info/10 text-info",
      "outline" => "border border-border text-foreground"
    }

    assigns = assign(assigns, :variant_class, Map.fetch!(variants, assigns.variant))

    ~H"""
    <span class={[
      "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium",
      @variant_class,
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Renders a metric/stat card for dashboards.

  ## Examples

      <.stat_card label="Active patients" value={12} icon="hero-users" />
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, default: nil
  attr :tone, :string, default: "bg-primary/10 text-primary"
  attr :class, :any, default: nil
  attr :rest, :global

  def stat_card(assigns) do
    ~H"""
    <div
      class={[
        "flex items-center gap-4 rounded-lg border bg-card p-5 text-card-foreground shadow-sm transition hover:shadow-md",
        @class
      ]}
      {@rest}
    >
      <div
        :if={@icon}
        class={["flex size-11 shrink-0 items-center justify-center rounded-lg", @tone]}
      >
        <.icon name={@icon} class="size-6" />
      </div>
      <div class="min-w-0">
        <p class="text-2xl font-semibold leading-tight">{@value}</p>
        <p class="text-sm text-muted-foreground">{@label}</p>
      </div>
    </div>
    """
  end

  @doc """
  Renders an empty state placeholder.

  ## Examples

      <.empty_state icon="hero-inbox" title="Nothing here yet" />
  """
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div class={["flex flex-col items-center justify-center gap-2 px-4 py-10 text-center", @class]}>
      <.icon name={@icon} class="size-8 text-muted-foreground/60" />
      <p class="text-sm font-medium text-foreground">{@title}</p>
      <p :if={@inner_block != []} class="text-sm text-muted-foreground">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end

  @doc """
  Renders a colored initials avatar derived from a name.

  ## Examples

      <.avatar name="Ana Beatriz" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-9"

  @avatar_tones [
    "bg-primary/15 text-primary",
    "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400",
    "bg-amber-500/15 text-amber-600 dark:text-amber-400",
    "bg-sky-500/15 text-sky-600 dark:text-sky-400",
    "bg-rose-500/15 text-rose-600 dark:text-rose-400",
    "bg-fuchsia-500/15 text-fuchsia-600 dark:text-fuchsia-400"
  ]

  def avatar(assigns) do
    assigns =
      assigns
      |> assign(:initials, avatar_initials(assigns.name))
      |> assign(
        :tone,
        Enum.at(@avatar_tones, :erlang.phash2(assigns.name, length(@avatar_tones)))
      )

    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center justify-center rounded-full text-xs font-semibold",
      @tone,
      @class
    ]}>
      {@initials}
    </span>
    """
  end

  defp avatar_initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.upcase(String.first(&1) || ""))
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  @input_base "flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:cursor-not-allowed disabled:opacity-50"
  @input_error "border-destructive focus-visible:ring-destructive"
  @label_class "mb-1.5 block text-sm font-medium text-foreground"

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-3">
      <label for={@id} class="flex items-center gap-2 text-sm">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@class || "size-4 rounded border-input text-primary focus:ring-2 focus:ring-ring"}
          {@rest}
        />
        <span>{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label :if={@label} for={@id} class={label_class()}>{@label}</label>
      <select
        id={@id}
        name={@name}
        class={[@class || input_base(), @errors != [] && (@error_class || input_error())]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label :if={@label} for={@id} class={label_class()}>{@label}</label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "min-h-[80px] py-2",
          @class || input_base(),
          @errors != [] && (@error_class || input_error())
        ]}
        {@rest}
      >{Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="mb-3">
      <label :if={@label} for={@id} class={label_class()}>{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Form.normalize_value(@type, @value)}
        class={[@class || input_base(), @errors != [] && (@error_class || input_error())]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # token helpers usable inside ~H class lists
  defp input_base, do: @input_base
  defp input_error, do: @input_error
  defp label_class, do: @label_class

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-1.5 text-sm text-destructive">
      <.icon name="hero-exclamation-circle" class="size-4" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[
      @actions != [] && "flex flex-wrap items-center justify-between gap-4",
      "pb-5",
      @class
    ]}>
      <div>
        <h1 class="text-xl font-semibold leading-tight tracking-tight">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-muted-foreground">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto rounded-lg border bg-card">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b bg-muted/40 text-left text-xs font-medium uppercase tracking-wide text-muted-foreground">
            <th :for={col <- @col} class="px-4 py-3">{col[:label]}</th>
            <th :if={@action != []} class="px-4 py-3">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="border-b last:border-0 hover:bg-muted/30"
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={["px-4 py-3", @row_click && "cursor-pointer"]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 px-4 py-3 font-medium">
              <div class="flex gap-3">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="divide-y divide-border">
      <li :for={item <- @item} class="flex items-baseline justify-between gap-4 py-3">
        <span class="text-sm text-muted-foreground">{item.title}</span>
        <span class="text-sm font-medium">{render_slot(item)}</span>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(RavanshenasiWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(RavanshenasiWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
