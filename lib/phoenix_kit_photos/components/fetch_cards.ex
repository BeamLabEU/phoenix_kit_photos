defmodule PhoenixKitPhotos.Components.FetchCards do
  @moduledoc """
  A fetch from a link as a card: what it is, how far it is, and the buttons that apply
  to where it stands. The library's `PhoenixKitPhotos.Components.LinkFetcher` shows its
  fetches this way, and so does the person's list (`PhoenixKitPhotos.Components.FetchList`).

  Every button sends its event to `target` with the fetch's `uuid`: `"open"` (the
  dialog of a fetch the person has not confirmed yet), `"cancel"`, `"retry"`,
  `"dismiss"`.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitPhotos.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitPhotos.Fetches
  alias PhoenixKitPhotos.Fetches.Fetch

  attr :fetch, Fetch, required: true
  attr :target, :any, required: true
  attr :waiting, :integer, default: 0, doc: "how many of the person's fetches go first"
  attr :library_name, :string, default: nil, doc: "shown where the card is not in its library"
  attr :library_href, :string, default: nil

  @doc "One fetch."
  def card(assigns) do
    assigns =
      assigns
      |> assign(:progress, assigns.fetch.progress || %{})
      |> assign(:info, assigns.fetch.info || %{})

    ~H"""
    <div
      id={"fetch-#{@fetch.uuid}"}
      class="flex items-start gap-3 rounded-box border border-base-300 bg-base-100 p-3 shadow-sm"
      role="status"
      aria-live="polite"
    >
      <.thumb info={@info} status={@fetch.status} />
      <div class="min-w-0 flex-1">
        <p class="truncate text-sm font-medium" title={@fetch.url}>{headline(@fetch)}</p>
        <p class="truncate text-xs text-base-content/60">
          {@fetch.site}
          <span :if={@library_name}>
            · <a :if={@library_href} href={@library_href} class="link link-hover">{@library_name}</a><span :if={!@library_href}>{@library_name}</span>
          </span>
        </p>

        <.state fetch={@fetch} progress={@progress} waiting={@waiting} />

        <div class="mt-2 flex flex-wrap gap-1">
          <button
            :if={@fetch.status == "ready"}
            type="button"
            phx-click="open"
            phx-value-uuid={@fetch.uuid}
            phx-target={@target}
            class="btn btn-primary btn-xs"
          >
            {gettext("Review and fetch")}
          </button>
          <button
            :if={@fetch.status in ["probing", "unavailable"]}
            type="button"
            phx-click="open"
            phx-value-uuid={@fetch.uuid}
            phx-target={@target}
            class="btn btn-ghost btn-xs"
          >
            {gettext("Details")}
          </button>
          <button
            :if={retry?(@fetch)}
            type="button"
            phx-click="retry"
            phx-value-uuid={@fetch.uuid}
            phx-target={@target}
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-arrow-path" class="h-3.5 w-3.5" />
            {gettext("Try again")}
          </button>
          <button
            :if={@fetch.status in ["queued", "running"]}
            type="button"
            phx-click="cancel"
            phx-value-uuid={@fetch.uuid}
            phx-target={@target}
            class="btn btn-ghost btn-xs"
            data-confirm={gettext("Stop this fetch? What is saved so far stays.")}
          >
            {gettext("Stop")}
          </button>
        </div>
      </div>
      <button
        :if={@fetch.status in ["done", "failed", "cancelled"]}
        type="button"
        phx-click="dismiss"
        phx-value-uuid={@fetch.uuid}
        phx-target={@target}
        class="btn btn-ghost btn-xs btn-circle"
        aria-label={gettext("Remove from the list")}
        title={gettext("Remove from the list")}
      >
        <.icon name="hero-x-mark" class="h-4 w-4" />
      </button>
      <button
        :if={@fetch.status in ["probing", "ready", "unavailable"]}
        type="button"
        phx-click="cancel"
        phx-value-uuid={@fetch.uuid}
        phx-target={@target}
        class="btn btn-ghost btn-xs btn-circle"
        aria-label={gettext("Forget this link")}
        title={gettext("Forget this link")}
      >
        <.icon name="hero-x-mark" class="h-4 w-4" />
      </button>
    </div>
    """
  end

  attr :info, :map, required: true
  attr :status, :string, required: true

  defp thumb(assigns) do
    ~H"""
    <div class="flex h-12 w-12 shrink-0 items-center justify-center overflow-hidden rounded-lg bg-base-200">
      <img
        :if={is_binary(@info["thumbnail"]) and String.starts_with?(@info["thumbnail"], "https://")}
        src={@info["thumbnail"]}
        alt=""
        loading="lazy"
        referrerpolicy="no-referrer"
        class="h-full w-full object-cover"
      />
      <span :if={!is_binary(@info["thumbnail"]) and @status == "probing"} class="loading loading-spinner loading-sm"></span>
      <.icon
        :if={!is_binary(@info["thumbnail"]) and @status != "probing"}
        name={if @info["video"], do: "hero-film", else: "hero-link"}
        class="h-5 w-5 text-base-content/50"
      />
    </div>
    """
  end

  attr :fetch, Fetch, required: true
  attr :progress, :map, required: true
  attr :waiting, :integer, required: true

  defp state(%{fetch: %Fetch{status: "running"}} = assigns) do
    ~H"""
    <div class="mt-1">
      <progress
        :if={is_integer(@progress["total_bytes"]) and @progress["total_bytes"] > 0}
        class="progress progress-primary w-full"
        value={min(@progress["bytes"] || 0, @progress["total_bytes"])}
        max={@progress["total_bytes"]}
      >
      </progress>
      <progress
        :if={!(is_integer(@progress["total_bytes"]) and @progress["total_bytes"] > 0)}
        class="progress progress-primary w-full"
      >
      </progress>
      <p class="mt-0.5 flex flex-wrap gap-x-2 text-xs text-base-content/70">
        <span>{phase(@progress["phase"])}</span>
        <span :if={(@progress["items"] || 0) > 1}>
          {gettext("%{item} of %{items}", item: max(@progress["item"] || 1, 1), items: @progress["items"])}
        </span>
        <span :if={is_integer(@progress["total_bytes"])}>
          {bytes(@progress["bytes"])} / {bytes(@progress["total_bytes"])}
        </span>
        <span :if={is_integer(@progress["speed"]) and @progress["speed"] > 0}>{bytes(@progress["speed"])}/s</span>
        <span :if={is_integer(@progress["eta"]) and @progress["eta"] > 0}>{gettext("%{time} left", time: duration(@progress["eta"]))}</span>
        <span :if={(@progress["saved"] || 0) > 0}>{ngettext("%{count} saved", "%{count} saved", @progress["saved"])}</span>
      </p>
    </div>
    """
  end

  defp state(%{fetch: %Fetch{status: "queued"}} = assigns) do
    ~H"""
    <p class="mt-1 text-xs text-base-content/70">
      <%= if @waiting > 0 do %>
        {ngettext("Waiting: 1 fetch goes first", "Waiting: %{count} fetches go first", @waiting)}
      <% else %>
        {gettext("Waiting to start…")}
      <% end %>
    </p>
    """
  end

  defp state(%{fetch: %Fetch{status: "probing"}} = assigns) do
    ~H"""
    <p class="mt-1 text-xs text-base-content/70">{gettext("Looking at the link…")}</p>
    """
  end

  defp state(%{fetch: %Fetch{status: "ready"}} = assigns) do
    ~H"""
    <p class="mt-1 text-xs text-base-content/70">{gettext("Found. Waiting for you to confirm.")}</p>
    """
  end

  defp state(%{fetch: %Fetch{status: status}} = assigns)
       when status in ["unavailable", "failed"] do
    ~H"""
    <p :if={(@progress["saved"] || 0) > 0} class="mt-1 text-xs text-base-content/70">
      {ngettext("%{count} file saved before it stopped.", "%{count} files saved before it stopped.", @progress["saved"])}
    </p>
    <p class="mt-1 text-xs text-error">{Fetches.error_message(@fetch)}</p>
    """
  end

  defp state(%{fetch: %Fetch{status: "cancelled"}} = assigns) do
    ~H"""
    <p class="mt-1 text-xs text-base-content/70">
      {gettext("Stopped.")}
      <span :if={(@progress["saved"] || 0) > 0}>{ngettext("%{count} file saved.", "%{count} files saved.", @progress["saved"])}</span>
    </p>
    """
  end

  defp state(%{fetch: %Fetch{status: "done"}} = assigns) do
    ~H"""
    <p class="mt-1 flex flex-wrap gap-x-2 text-xs">
      <span :if={(@progress["saved"] || 0) > 0} class="text-success">
        {ngettext("%{count} file added", "%{count} files added", @progress["saved"])}
      </span>
      <span :if={(@progress["duplicates"] || 0) > 0} class="text-base-content/70">
        {ngettext("%{count} was already here", "%{count} were already here", @progress["duplicates"])}
      </span>
      <span :if={(@progress["failed"] || 0) > 0} class="text-warning">
        {ngettext("%{count} could not be fetched", "%{count} could not be fetched", @progress["failed"])}
      </span>
    </p>
    <p :if={(@progress["failed"] || 0) > 0 and @fetch.error_code} class="mt-0.5 text-xs text-base-content/60">
      {Fetches.error_message(@fetch)}
    </p>
    """
  end

  defp state(assigns), do: ~H""

  defp headline(%Fetch{info: %{"title" => title}}) when is_binary(title) and title != "",
    do: title

  defp headline(%Fetch{url: url}), do: url

  defp retry?(%Fetch{status: status}) when status in ["unavailable", "failed", "cancelled"],
    do: true

  defp retry?(%Fetch{status: "done", progress: %{"failed" => n}}) when is_integer(n) and n > 0,
    do: true

  defp retry?(_fetch), do: false

  @doc "What a running fetch is doing, in words."
  def phase("joining"), do: gettext("Joining video and sound")
  def phase("saving"), do: gettext("Saving")
  def phase("starting"), do: gettext("Starting")
  def phase("waiting"), do: gettext("Waiting")
  def phase(_downloading), do: gettext("Downloading")

  @doc "A size for people: `1.5 MB`."
  def bytes(nil), do: "–"
  def bytes(n) when n < 1_024, do: "#{n} B"
  def bytes(n) when n < 1_048_576, do: "#{Float.round(n / 1_024, 0) |> trunc()} KB"
  def bytes(n) when n < 1_073_741_824, do: "#{Float.round(n / 1_048_576, 1)} MB"
  def bytes(n), do: "#{Float.round(n / 1_073_741_824, 2)} GB"

  @doc "A length of time: `4:05`, `1:02:03`."
  def duration(nil), do: nil

  def duration(seconds) when is_integer(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    s = rem(seconds, 60)
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{m}:#{pad.(s)}"
  end
end
