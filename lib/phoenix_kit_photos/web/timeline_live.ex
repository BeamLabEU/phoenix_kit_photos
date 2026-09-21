defmodule PhoenixKitPhotos.Web.TimelineLive do
  @moduledoc """
  The package's default timeline page.

  A host that wants its own branding declares its own route at the same path
  *before* `phoenix_kit_routes()` in its router — first match wins, so the host
  page shadows this one while every other install still gets a working page.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.Components.PhotoTimeline
  alias PhoenixKitWeb.Components.LayoutWrapper

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Photos"))}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :user_uuid, current_user_uuid(assigns))

    ~H"""
    <LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={gettext("Photos")}
      current_path={assigns[:url_path]}
    >
      <div :if={is_nil(@user_uuid)} class="alert alert-info" role="status">
        {gettext("Sign in to see your photo library.")}
      </div>

      <.live_component
        :if={@user_uuid}
        module={PhotoTimeline}
        id="photo-timeline"
        scope={{:user, @user_uuid}}
        layout={:square}
        columns={5}
      />
    </LayoutWrapper.app_layout>
    """
  end

  # This route is reachable unauthenticated (the root, non-localized shape), so
  # a missing user is an ordinary state rather than a crash.
  defp current_user_uuid(assigns) do
    case Scope.user(assigns[:phoenix_kit_current_scope]) do
      %{uuid: uuid} when is_binary(uuid) -> uuid
      _ -> nil
    end
  end
end
