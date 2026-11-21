defmodule PhoenixKitPhotos.Components.CDNSettings do
  @moduledoc "Library owner's CDN connection and rendition preferences."
  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitPhotos.Gettext
  alias PhoenixKit.Modules.Storage.{CDN, Libraries, VariantSets}
  alias PhoenixKit.PubSub.Manager

  @impl true
  def update(assigns, socket),
    do: {:ok, socket |> assign(assigns) |> assign(:notice, nil) |> load()}

  defp load(socket) do
    library = Libraries.get_library(socket.assigns.library_uuid)
    editable = CDN.owner?(socket.assigns.auth, library)
    policy = CDN.preferences(library)
    set = VariantSets.set_uuid_for(library)
    site = CDN.site_connection()

    assign(socket,
      editable: editable,
      policy: policy,
      rows: CDN.rows(set),
      defaults: CDN.site_renditions(set),
      site: if(site == "bucket", do: gettext("Use bucket mappings"), else: gettext("Off"))
    )
  end

  @impl true
  def handle_event("change", params, socket) do
    public =
      case params["public"] do
        ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
        _ -> []
      end

    public =
      if socket.assigns.policy["mode"] == "inherit" and params["mode"] == "custom",
        do: socket.assigns.defaults,
        else: public

    policy = Map.take(params, ["mode", "connection"]) |> Map.put("public", public)
    {:noreply, assign(socket, :policy, policy)}
  end

  def handle_event("save", params, socket) do
    case CDN.save_library(socket.assigns.auth, socket.assigns.library_uuid, params) do
      {:ok, _} ->
        Manager.broadcast(
          "storage:library_settings",
          {:library_settings_changed, socket.assigns.library_uuid}
        )

        {:noreply, socket |> load() |> assign(:notice, gettext("Saved"))}

      {:error, _} ->
        {:noreply, socket |> load() |> assign(:notice, gettext("Could not save CDN preferences"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <form id={@id} phx-change="change" phx-submit="save" phx-target={@myself} class="space-y-4">
      <fieldset class="fieldset" disabled={!@editable}>
        <label><span>{gettext("CDN delivery")}</span>
          <select name="connection" class="select">
            <option value="inherit" selected={@policy["connection"] == "inherit"}>{gettext("Site default (%{name})", name: @site)}</option>
            <option value="off" selected={@policy["connection"] == "off"}>{gettext("Off")}</option>
            <option value="bucket" selected={@policy["connection"] == "bucket"}>{gettext("Use bucket mappings")}</option>
          </select>
        </label>
        <label><span>{gettext("Renditions")}</span>
          <select name="mode" class="select">
            <option value="inherit" selected={@policy["mode"] == "inherit"}>{gettext("Use site defaults")}</option>
            <option value="custom" selected={@policy["mode"] == "custom"}>{gettext("Choose renditions")}</option>
          </select>
        </label>
        <PhoenixKitWeb.Live.Modules.Storage.CDNSettings.matrix rows={@rows} selected={if @policy["mode"] == "inherit", do: @defaults, else: @policy["public"]} disabled={!@editable or @policy["mode"] == "inherit"} />
      </fieldset>
      <p>{gettext("Delivery currently uses library storage.")}</p>
      <button :if={@editable} class="btn btn-primary btn-sm">{gettext("Save")}</button>
      <span role="status">{@notice}</span>
    </form>
    """
  end
end
