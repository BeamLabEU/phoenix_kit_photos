defmodule PhoenixKitPhotos.Viewer do
  @moduledoc """
  Which viewer a library's photos open in.

  Two are offered:

    * `"photoswipe"` — the swipe viewer (`PhoenixKitPhotos.Components.PhotoTimeline`'s `pager`,
      engine `photoswipe`): swipe between photos and videos, pinch and double-tap zoom, drag
      down to close;
    * `"classic"` — PhoenixKit's own media viewer (`MediaCanvasViewer`), one file at a time
      with its sidebar and comments.

  A library chooses one (`Libraries.setting(library, :viewer)`, stored in the library's own
  settings, so it follows the library and not the browser). A library that has not chosen
  follows `default/0`: `config :phoenix_kit_photos, default_viewer: "classic"`, otherwise
  `"photoswipe"`. A name stored that this package does not offer (an engine it no longer
  has) is ignored: the library follows the default.

  The viewer's *engines* (`assets/js/viewer`) are a finer list than this one: `snap` is an
  engine and is not offered here.
  """

  use Gettext, backend: PhoenixKitPhotos.Gettext

  alias PhoenixKit.Modules.Storage.{Libraries, Library}
  alias PhoenixKit.Users.Auth.Scope

  @names ~w(photoswipe classic)

  @doc "The viewers a library can choose between, as `{name, label}`."
  @spec options() :: [{String.t(), String.t()}]
  def options do
    [{"photoswipe", gettext("Swipe viewer")}, {"classic", gettext("Classic viewer")}]
  end

  @doc "The viewer a library follows until it chooses."
  @spec default() :: String.t()
  def default do
    case Application.get_env(:phoenix_kit_photos, :default_viewer) do
      name when name in @names -> name
      _ -> "photoswipe"
    end
  end

  @doc """
  The viewer for a library (or its uuid; nil is Media): its own choice, or the
  default when it has none or a name this package does not offer.
  """
  @spec for_library(Library.t() | String.t() | nil) :: String.t()
  def for_library(library) do
    case Libraries.setting(library, :viewer) do
      name when name in @names -> name
      _ -> default()
    end
  end

  @doc "A library's own choice, or nil when it follows the default."
  @spec chosen(Library.t() | String.t() | nil) :: String.t() | nil
  def chosen(library) do
    case Libraries.setting(library, :viewer) do
      name when name in @names -> name
      _ -> nil
    end
  end

  @doc """
  What `PhotoTimeline`'s `pager` takes for a viewer: `false` for the classic one (the host
  opens its own on `on_open`), the engine's name for the swipe viewer.
  """
  @spec pager(String.t()) :: false | String.t()
  def pager("classic"), do: false
  def pager(name) when name in @names, do: name
  def pager(_name), do: pager(default())

  @doc """
  Whether `scope` may choose the viewer of `library`: a user library's owner and managers,
  and for a system library (Media) the site's owners and admins.
  """
  @spec can_set?(Scope.t() | nil, Library.t() | nil) :: boolean()
  def can_set?(%Scope{} = scope, %Library{trashed_at: nil} = library) do
    case library do
      %Library{kind: "user"} ->
        user_uuid = Scope.user_uuid(scope)
        is_binary(user_uuid) and Libraries.allows?(Libraries.role(library, user_uuid), :rename)

      %Library{kind: "system"} ->
        Scope.system_role?(scope)
    end
  end

  def can_set?(_scope, _library), do: false

  @doc """
  Sets the viewer of `library` for `scope`: a name from `options/0`, or nil to follow the
  default. `{:error, :not_allowed}` for someone who may not, `{:error, :unknown_viewer}`
  for a name not offered.
  """
  @spec put(Scope.t() | nil, Library.t(), String.t() | nil) ::
          {:ok, Library.t()} | {:error, :not_allowed | :unknown_viewer | term()}
  def put(scope, %Library{} = library, name) when is_nil(name) or name in @names do
    if can_set?(scope, library) do
      Libraries.put_setting(library, :viewer, name, actor_uuid: Scope.user_uuid(scope))
    else
      {:error, :not_allowed}
    end
  end

  def put(_scope, _library, _name), do: {:error, :unknown_viewer}
end
