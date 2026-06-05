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

    # subscribe só no socket conectado (evita subscribe inútil no render desconectado)
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
      <.header>{gettext("WhatsApp audios")} — {@patient.name}</.header>

      <form id="audio-upload-form" phx-submit="transcribe" phx-change="validate">
        <.live_file_input upload={@uploads.audio} />
        <select name="tone">
          <option :for={{label, value} <- @tones} value={value}>{label}</option>
        </select>
        <.button type="submit">{gettext("Transcribe and suggest")}</.button>
      </form>

      <ul id="audios">
        <li :for={a <- @audios} id={"audio-#{a.id}"}>
          <span>{a.original_filename}</span>
          <span id={"audio-status-#{a.id}"} data-status={a.status}>{status_label(a.status)}</span>

          <p :if={a.transcription} id={"transcription-#{a.id}"}>{a.transcription}</p>

          <div :if={a.status == :done}>
            <form id={"response-form-#{a.id}"} phx-submit="save-response">
              <input type="hidden" name="_id" value={a.id} />
              <textarea id={"suggested-response-#{a.id}"} name="response" rows="5">{a.suggested_response}</textarea>
              <.button type="submit">{gettext("Save")}</.button>
              <button
                type="button"
                id={"copy-response-#{a.id}"}
                phx-hook=".Copy"
                data-target={"#suggested-response-#{a.id}"}
              >
                {gettext("Copy")}
              </button>
            </form>
          </div>

          <div :if={a.status == :error} id={"audio-error-#{a.id}"}>
            <p>{gettext("Failed.")} {a.error_reason}</p>
            <.button
              :if={a.transcription}
              id={"retry-audio-#{a.id}"}
              phx-click="retry-audio"
              phx-value-id={a.id}
            >
              {gettext("Try again")}
            </.button>
            <p :if={is_nil(a.transcription)}>{gettext("Please upload the audio again.")}</p>
          </div>
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
        # create falhou: remove o binário copiado pra não deixar órfão no tmp
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
