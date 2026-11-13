defmodule PhoenixKitPhotos.Sharing do
  @moduledoc """
  What a library shares beyond its photos: **where they were taken**, and **who may
  comment** on them. Each library chooses; the owner and its managers set it (the same
  people who choose its viewer, `PhoenixKitPhotos.Viewer.can_set?/2`).

  ## Locations

  A phone writes the exact spot into every photo, and on a shared or public library the
  exact spot can give away someone's home. So:

    * `"members"` (the default): the owner and the library's members see where a photo was
      taken; everyone else who can see it sees no place at all;
    * `"area"`: members see the exact spot, everyone else only roughly where, a circle a
      few kilometres wide (`approximate/2`); the exact position never reaches their
      browser;
    * `"everyone"`: whoever can see the photo sees the exact spot.

  A member is someone with a role in the library (`Libraries.role/2`), or the site's
  owners and admins. This is about what this package shows; the original file a person
  downloads can still carry its GPS.

  ## Comments

    * `"viewers"` (the default): anyone signed in who can see the photo may comment;
      someone not signed in reads them;
    * `"members"`: only members read and write them;
    * `"off"`: no comments are shown.

  Both choices live in the library's settings under this package's namespace
  (`Libraries.module_setting(library, "photos", key)`), like the viewer's.
  """

  use Gettext, backend: PhoenixKitPhotos.Gettext

  alias PhoenixKit.Modules.Storage.{Libraries, Library}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitPhotos.Viewer

  @namespace "photos"
  @locations ~w(members area everyone)
  @comments ~w(viewers members off)

  # How coarse a place is for someone who may see only the area: positions are snapped
  # to a grid of this many degrees (about 5.5 km north to south), and the circle drawn
  # around the snapped point is wide enough to hold the real one.
  @area_step 0.05
  @area_radius_m 4_500

  @type audience :: :member | :viewer | :reader

  @doc "The location choices, as `{name, label, explanation}`."
  @spec location_options() :: [{String.t(), String.t(), String.t()}]
  def location_options do
    [
      {"members", gettext("Members only"),
       gettext("The owner and members see where each photo was taken. Nobody else does.")},
      {"area", gettext("Others see the area"),
       gettext(
         "Members see the exact spot. Everyone else sees only roughly where, a circle a few kilometres wide."
       )},
      {"everyone", gettext("Everyone who can see the photo"),
       gettext("Whoever can see a photo sees exactly where it was taken.")}
    ]
  end

  @doc "The comment choices, as `{name, label, explanation}`."
  @spec comment_options() :: [{String.t(), String.t(), String.t()}]
  def comment_options do
    [
      {"viewers", gettext("Anyone signed in who can see the photos"),
       gettext("People who are not signed in can read the comments.")},
      {"members", gettext("Members only"),
       gettext("Only the owner and members read and write comments.")},
      {"off", gettext("Nobody"), gettext("No comments are shown on this library's photos.")}
    ]
  end

  @doc ~s(Who sees where this library's photos were taken: `"members"`, `"area"` or `"everyone"`.)
  @spec locations(Library.t() | String.t() | nil) :: String.t()
  def locations(library), do: read(library, "locations", @locations, "members")

  @doc ~s(Who may comment on this library's photos: `"viewers"`, `"members"` or `"off"`.)
  @spec comments(Library.t() | String.t() | nil) :: String.t()
  def comments(library), do: read(library, "comments", @comments, "viewers")

  @doc """
  Sets `key` (`"locations"` or `"comments"`) of `library` to `value`, for `scope`.
  `{:error, :not_allowed}` for someone who may not, `{:error, :unknown}` for a value
  that is not offered.
  """
  @spec put(Scope.t() | nil, Library.t(), String.t(), String.t()) ::
          {:ok, Library.t()} | {:error, :not_allowed | :unknown | term()}
  def put(scope, %Library{} = library, key, value)
      when (key == "locations" and value in @locations) or
             (key == "comments" and value in @comments) do
    if Viewer.can_set?(scope, library) do
      Libraries.put_module_setting(library, @namespace, key, value,
        actor_uuid: Scope.user_uuid(scope)
      )
    else
      {:error, :not_allowed}
    end
  end

  def put(_scope, _library, _key, _value), do: {:error, :unknown}

  @doc """
  What `scope` is to `library`: `:member` (a role in it, or a site owner or admin),
  `:viewer` (signed in, no role) or `:reader` (not signed in). Whether they may see the
  library at all is decided elsewhere, before this is asked.
  """
  @spec audience(Scope.t() | nil, Library.t() | nil) :: audience()
  def audience(%Scope{} = scope, library) do
    user_uuid = Scope.user_uuid(scope)

    cond do
      not is_binary(user_uuid) -> :reader
      Scope.system_role?(scope) -> :member
      match?(%Library{}, library) and Libraries.role(library, user_uuid) != nil -> :member
      true -> :viewer
    end
  end

  def audience(_scope, _library), do: :reader

  @doc """
  How much of a photo's place `audience` sees in `library`: `:exact`, `:area` or `:none`.
  """
  @spec place_view(Library.t() | nil, audience()) :: :exact | :area | :none
  def place_view(_library, :member), do: :exact

  def place_view(library, _audience) do
    case locations(library) do
      "everyone" -> :exact
      "area" -> :area
      _ -> :none
    end
  end

  @doc """
  What `audience` may do with comments in `library`: `:write`, `:read` or `:none`.
  Comments also need the comments module to be on, which the caller checks.
  """
  @spec comment_view(Library.t() | nil, audience()) :: :write | :read | :none
  def comment_view(library, audience) do
    case {comments(library), audience} do
      {"off", _} -> :none
      {"members", :member} -> :write
      {"members", _} -> :none
      {"viewers", :reader} -> :read
      {"viewers", _} -> :write
    end
  end

  @doc """
  `{latitude, longitude}` snapped to the area grid, and the radius in metres of a circle
  around it that holds the real position. What someone who may see only the area gets:
  the snapped point, never the real one.
  """
  @spec approximate(number(), number()) :: {float(), float(), pos_integer()}
  def approximate(lat, lon) do
    {snap(lat), snap(lon), @area_radius_m}
  end

  defp snap(value), do: Float.round(Float.round(value / @area_step) * @area_step, 4)

  defp read(library, key, names, default) do
    case Libraries.module_setting(library, @namespace, key) do
      name when is_binary(name) -> if name in names, do: name, else: default
      _ -> default
    end
  end
end
