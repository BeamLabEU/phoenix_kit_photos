defmodule PhoenixKitPhotos.Components.PhotoTimeline do
  @moduledoc """
  The timeline LiveComponent: index and current window on the server, geometry
  and recycling in the `PhotoTimeline` JS hook.

  ## Usage

      <.live_component
        module={PhoenixKitPhotos.Components.PhotoTimeline}
        id="library"
        scope={{:user, user.uuid}}
        layout={:square}
        columns={5}
        on_open="open_asset"
      />

  ## The v1 contract is deliberately small

  `scope` accepts `{:user, uuid}` only. `{:album, id}` and `{:share, token}`
  are not here: PhoenixKit has folders rather than albums, and there are no
  library share tokens yet. Publishing a scope now means withdrawing it later.

  `layout` accepts `:square` only; `:justified` arrives in Stage 3. Square
  heights are exact — `ceil(count / columns) * (cell + gap) + header` — which
  is why the 10k contract test does not need tombstone refinement.

  There is no `on_select`: selection has no bulk action behind it yet.
  """

  use Phoenix.LiveComponent

  alias PhoenixKitPhotos.Timeline

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:index, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:scope, validate_scope!(assigns.scope))
      |> assign(:layout, validate_layout!(Map.get(assigns, :layout, :square)))
      |> assign(:columns, Map.get(assigns, :columns, 5))
      |> assign(:on_open, Map.get(assigns, :on_open))

    {:ok, load_index(socket)}
  end

  defp validate_scope!({:user, uuid} = scope) when is_binary(uuid), do: scope

  defp validate_scope!(other) do
    raise ArgumentError, """
    PhotoTimeline :scope must be {:user, uuid} in v1, got: #{inspect(other)}

    {:album, id} and {:share, token} are not part of the published contract yet.
    """
  end

  defp validate_layout!(:square), do: :square

  defp validate_layout!(:justified) do
    raise ArgumentError, ":justified layout arrives in Stage 3; use :square"
  end

  defp validate_layout!(other) do
    raise ArgumentError, "PhotoTimeline :layout must be :square, got: #{inspect(other)}"
  end

  # The scope check lives here, on the server. A signed thumbnail URL is not
  # authorization: URLSigner tokens are 4 hex characters and never expire.
  #
  # Stage 0: there is no {:ok, index} clause to write yet, because
  # Timeline.index/1 cannot succeed until the capture-date columns exist in
  # PhoenixKit core. Add it — and push "timeline:index" to the hook — in the
  # same change that makes the query real.
  defp load_index(socket) do
    {:error, reason} = Timeline.index(socket.assigns.scope)
    assign(socket, index: nil, error: reason)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="phoenix-kit-photo-timeline">
      <%= if @error do %>
        <div class="alert alert-warning" role="status">
          {error_message(@error)}
        </div>
      <% else %>
        <div
          id={"#{@id}-viewport"}
          phx-hook="PhotoTimeline"
          phx-update="ignore"
          data-columns={@columns}
          data-layout={@layout}
          class="phoenix-kit-photo-timeline__viewport"
        >
          <div class="phoenix-kit-photo-timeline__spacer"></div>
        </div>
      <% end %>
    </div>
    """
  end

  defp error_message(:capture_date_unavailable) do
    "Photos needs capture-date columns on phoenix_kit_files (Stage 0). " <>
      "Nothing is shown rather than bucketing a library by upload date."
  end

  defp error_message(other), do: "Photos is unavailable: #{inspect(other)}"
end
