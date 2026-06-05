defmodule RavanshenasiWeb.AudioLive.Index do
  use RavanshenasiWeb, :live_view

  alias Ravanshenasi.{AudioMessages, Patients}

  @tones [
    {"Empático", "empathetic"},
    {"Informativo", "informative"},
    {"Encorajador", "encouraging"}
  ]

  @impl true
  def mount(%{"patient_id" => pid}, _session, socket) do
    scope = socket.assigns.current_scope
    patient = Patients.get_patient!(scope, pid)
    audios = AudioMessages.list_audio_messages(scope, %{id: patient.id})

    # Subscribe only on the connected socket to avoid useless subscriptions during disconnected render.
    if connected?(socket) do
      for a <- audios,
          a.status in [:pending, :transcribing, :suggesting],
          do: AudioMessages.subscribe(a.id)
    end

    {:ok,
     socket
     |> assign(patient: patient, audios: audios, tones: @tones)
     |> allow_upload(:audio,
       accept: ~w(.ogg .mp3 .m4a .wav),
       max_file_size: 25_000_000,
       max_entries: 1
     )}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("transcribe", %{"tone" => tone}, socket) do
    scope = socket.assigns.current_scope
    patient = socket.assigns.patient

    consumed =
      consume_uploaded_entries(socket, :audio, fn %{path: tmp}, entry ->
        dir = Path.join(System.tmp_dir!(), "ravanshenasi_audio")
        File.mkdir_p!(dir)
        dest = Path.join(dir, "#{Ecto.UUID.generate()}#{Path.extname(entry.client_name)}")
        File.cp!(tmp, dest)
        {:ok, {dest, entry.client_name}}
      end)

    case consumed do
      [{audio_path, filename}] ->
        create_from_upload(socket, scope, patient, audio_path, filename, tone)

      [] ->
        {:noreply, put_flash(socket, :error, gettext("Select an audio file"))}
    end
  end

  @impl true
  def handle_event("save-response", %{"_id" => id, "response" => text}, socket) do
    case AudioMessages.update_suggested_response(socket.assigns.current_scope, %{id: id}, text) do
      {:ok, msg} ->
        audios = replace_audio(socket.assigns.audios, msg)
        {:noreply, socket |> assign(audios: audios) |> put_flash(:info, gettext("Saved"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save"))}
    end
  end

  @impl true
  def handle_event("retry-audio", %{"id" => id}, socket) do
    case AudioMessages.retry_suggestion(socket.assigns.current_scope, %{id: id}) do
      {:ok, msg} ->
        AudioMessages.subscribe(msg.id)
        {:noreply, assign(socket, audios: replace_audio(socket.assigns.audios, msg))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not retry"))}
    end
  end

  @impl true
  def handle_info({:audio_updated, msg}, socket) do
    {:noreply, assign(socket, audios: replace_audio(socket.assigns.audios, msg))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        <span class="flex items-center gap-3">
          <.avatar name={@patient.name} class="size-8" />
          {gettext("WhatsApp audios")} — {@patient.name}
        </span>
        <:subtitle>{gettext("Upload and transcribe audio messages from patients")}</:subtitle>
      </.header>

      <.card class="max-w-xl">
        <:title>{gettext("New audio")}</:title>
        <form id="audio-upload-form" phx-submit="transcribe" phx-change="validate" class="space-y-4">
          <div>
            <label class="mb-1.5 block text-sm font-medium text-foreground">
              {gettext("Audio file")}
            </label>
            <.live_file_input upload={@uploads.audio} class="text-sm text-muted-foreground" />
          </div>
          <div>
            <label class="mb-1.5 block text-sm font-medium text-foreground">
              {gettext("Tone")}
            </label>
            <select
              name="tone"
              class="w-full rounded-md border border-border bg-card px-3 py-2 text-sm text-card-foreground shadow-sm focus:outline-none focus:ring-2 focus:ring-ring"
            >
              <option :for={{label, value} <- @tones} value={value}>{label}</option>
            </select>
          </div>
          <div class="flex justify-end">
            <.button type="submit">{gettext("Transcribe and suggest")}</.button>
          </div>
        </form>
      </.card>

      <.empty_state :if={@audios == []} icon="hero-microphone" title={gettext("No audios yet.")}>
        {gettext("Upload an audio above to get started.")}
      </.empty_state>

      <ul :if={@audios != []} id="audios" class="mt-4 space-y-4">
        <li :for={a <- @audios} id={"audio-#{a.id}"}>
          <.card>
            <:title>
              <div class="flex items-center justify-between gap-3">
                <span class="min-w-0 truncate font-medium">{a.original_filename}</span>
                <span class="flex items-center gap-1.5">
                  <%!-- data-status preserved for tests --%>
                  <span
                    id={"audio-status-#{a.id}"}
                    data-status={a.status}
                    class="sr-only"
                  >
                    {status_label(a.status)}
                  </span>
                  <.status_badge value={a.status} />
                </span>
              </div>
            </:title>

            <div
              :if={a.status in [:pending, :transcribing, :suggesting]}
              class="flex items-center gap-2 text-sm text-muted-foreground"
            >
              <.icon name="hero-arrow-path" class="size-4 animate-spin" />
              {status_label(a.status)}
            </div>

            <div :if={a.transcription} class="rounded-md bg-muted p-3 text-sm text-muted-foreground">
              <p class="mb-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">
                {gettext("Transcription")}
              </p>
              <p id={"transcription-#{a.id}"}>{a.transcription}</p>
            </div>

            <div :if={a.status == :done} class="mt-4">
              <form id={"response-form-#{a.id}"} phx-submit="save-response" class="space-y-3">
                <input type="hidden" name="_id" value={a.id} />
                <div>
                  <label class="mb-1.5 block text-sm font-medium text-foreground">
                    {gettext("Suggested response")}
                  </label>
                  <textarea
                    id={"suggested-response-#{a.id}"}
                    name="response"
                    rows="5"
                    class="w-full rounded-md border border-border bg-card px-3 py-2 text-sm text-card-foreground shadow-sm focus:outline-none focus:ring-2 focus:ring-ring"
                  >{a.suggested_response}</textarea>
                </div>
                <div class="flex items-center justify-end gap-2">
                  <button
                    type="button"
                    id={"copy-response-#{a.id}"}
                    phx-hook=".Copy"
                    data-target={"#suggested-response-#{a.id}"}
                    class="inline-flex items-center gap-1.5 rounded-md border border-border bg-card px-3 py-1.5 text-sm font-medium text-card-foreground shadow-sm hover:bg-accent"
                  >
                    <.icon name="hero-clipboard" class="size-4" />
                    {gettext("Copy")}
                  </button>
                  <.button type="submit">
                    <.icon name="hero-check" class="size-4" />
                    {gettext("Save")}
                  </.button>
                </div>
              </form>
            </div>

            <div :if={a.status == :error} id={"audio-error-#{a.id}"} class="mt-2 space-y-3">
              <div class="flex items-start gap-2 rounded-md bg-destructive/10 p-3 text-sm text-destructive">
                <.icon name="hero-exclamation-circle" class="size-4 mt-0.5 shrink-0" />
                <span>{gettext("Failed.")} {a.error_reason}</span>
              </div>
              <div :if={a.transcription} class="flex justify-end">
                <.button
                  id={"retry-audio-#{a.id}"}
                  variant="outline"
                  phx-click="retry-audio"
                  phx-value-id={a.id}
                >
                  <.icon name="hero-arrow-path" class="size-4" />
                  {gettext("Try again")}
                </.button>
              </div>
              <p :if={is_nil(a.transcription)} class="text-sm text-muted-foreground">
                {gettext("Please upload the audio again.")}
              </p>
            </div>
          </.card>
        </li>
      </ul>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const target = document.querySelector(this.el.dataset.target)
              if (target) { target.select(); navigator.clipboard.writeText(target.value) }
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp replace_audio(audios, msg),
    do: Enum.map(audios, fn a -> if a.id == msg.id, do: msg, else: a end)

  defp create_from_upload(socket, scope, patient, audio_path, filename, tone) do
    case AudioMessages.create_audio_message(scope, patient, %{
           audio_path: audio_path,
           original_filename: filename,
           tone: tone
         }) do
      {:ok, msg} ->
        AudioMessages.subscribe(msg.id)
        {:noreply, assign(socket, audios: [msg | socket.assigns.audios])}

      {:error, :unauthorized} ->
        # Creation failed: remove the copied binary so tmp does not keep an orphan.
        File.rm(audio_path)
        {:noreply, put_flash(socket, :error, gettext("Not allowed"))}

      {:error, _} ->
        File.rm(audio_path)
        {:noreply, put_flash(socket, :error, gettext("Could not process the audio"))}
    end
  end

  defp status_label(:pending), do: gettext("Queued…")
  defp status_label(:transcribing), do: gettext("Transcribing…")
  defp status_label(:suggesting), do: gettext("Generating reply…")
  defp status_label(:done), do: gettext("Done")
  defp status_label(:error), do: gettext("Error")
end
