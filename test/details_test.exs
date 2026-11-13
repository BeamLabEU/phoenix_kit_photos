defmodule PhoenixKitPhotos.DetailsTest do
  @moduledoc """
  The swipe viewer's info panel's data (`PhoenixKitPhotos.Details`) and the library's choices
  it follows (`PhoenixKitPhotos.Sharing`): who sees which place, who may comment, and the
  changes, each checked for the person making it.
  """

  use PhoenixKitPhotos.DataCase, async: false

  alias PhoenixKit.Modules.Storage.ManualLocation
  alias PhoenixKitPhotos.{Details, Sharing}

  setup do
    # Changes are announced on PhoenixKit's internal PubSub.
    _ = start_supervised(PhoenixKit.PubSub.Manager)
    n = System.unique_integer([:positive])
    owner = user_fixture("owner-#{n}@example.com")
    member = user_fixture("member-#{n}@example.com")
    visitor = user_fixture("visitor-#{n}@example.com")

    library = library_fixture(owner)
    member_fixture(library, member, "viewer")
    # Anyone with the address may look: a visitor and someone signed in without a role.
    library = library |> Ecto.Changeset.change(visibility: "site") |> TestRepo.update!()

    photo =
      file_fixture(owner, %{
        library_uuid: library.uuid,
        latitude: 59.437,
        longitude: 24.7453,
        metadata: %{"exif" => %{"gps" => %{"latitude" => 59.437, "longitude" => 24.7453}}}
      })

    %{
      owner: owner,
      member: member,
      visitor: visitor,
      library: library,
      photo: photo,
      scope: {:library, library.uuid}
    }
  end

  defp load!(ctx, user) do
    auth = user && scope_for(user)
    {:ok, details} = Details.load(ctx.scope, ctx.photo.uuid, auth, "en")
    details
  end

  describe "Sharing" do
    test "who is who to a library", ctx do
      assert Sharing.audience(scope_for(ctx.owner), ctx.library) == :member
      assert Sharing.audience(scope_for(ctx.member), ctx.library) == :member
      assert Sharing.audience(scope_for(ctx.visitor), ctx.library) == :viewer
      assert Sharing.audience(nil, ctx.library) == :reader
    end

    test "the defaults: places for members, comments from anyone signed in", ctx do
      assert Sharing.locations(ctx.library) == "members"
      assert Sharing.comments(ctx.library) == "viewers"
      assert Sharing.place_view(ctx.library, :member) == :exact
      assert Sharing.place_view(ctx.library, :viewer) == :none
      assert Sharing.comment_view(ctx.library, :viewer) == :write
      assert Sharing.comment_view(ctx.library, :reader) == :read
    end

    test "only the owner (or a manager) chooses, and only what is offered", ctx do
      assert {:error, :not_allowed} =
               Sharing.put(scope_for(ctx.member), ctx.library, "locations", "everyone")

      assert {:error, :unknown} =
               Sharing.put(scope_for(ctx.owner), ctx.library, "locations", "street")

      assert {:ok, library} = Sharing.put(scope_for(ctx.owner), ctx.library, "locations", "area")
      assert Sharing.locations(library) == "area"
      assert Sharing.place_view(library, :viewer) == :area
      assert Sharing.place_view(library, :member) == :exact

      assert {:ok, library} = Sharing.put(scope_for(ctx.owner), library, "comments", "members")
      assert Sharing.comment_view(library, :viewer) == :none
      assert Sharing.comment_view(library, :member) == :write

      assert {:ok, library} = Sharing.put(scope_for(ctx.owner), library, "comments", "off")
      assert Sharing.comment_view(library, :member) == :none
    end

    test "an area is a snapped point and a circle that holds the real one" do
      {lat, lon, radius} = Sharing.approximate(59.437, 24.7453)
      assert {lat, lon} == {59.45, 24.75}
      # The real point is inside the circle: about 1.5 km away, the circle 4.5 km.
      assert haversine_m(59.437, 24.7453, lat, lon) < radius
    end
  end

  describe "what each person sees" do
    test "the owner: everything, to edit", ctx do
      details = load!(ctx, ctx.owner)
      assert details.editor?
      assert details.audience == :member
      assert %{view: :exact, latitude: 59.437, longitude: 24.7453} = details.place
      assert details.comments == :write
      assert details.date.source == "exif"
      assert Map.has_key?(details.own, details.lang)
    end

    test "a member: the exact place, nothing to edit", ctx do
      details = load!(ctx, ctx.member)
      refute details.editor?
      assert details.own == nil
      assert details.place.view == :exact
    end

    test "someone signed in without a role: no place until the library shows it", ctx do
      assert load!(ctx, ctx.visitor).place == nil

      {:ok, _} = Sharing.put(scope_for(ctx.owner), ctx.library, "locations", "area")
      place = load!(ctx, ctx.visitor).place
      assert place.view == :area
      # Never the real position.
      assert {place.latitude, place.longitude} == {59.45, 24.75}
      assert place.radius > 0

      {:ok, _} = Sharing.put(scope_for(ctx.owner), ctx.library, "locations", "everyone")
      assert %{view: :exact, latitude: 59.437} = load!(ctx, ctx.visitor).place
    end

    test "a visitor reads comments; with comments for members only, sees none", ctx do
      assert load!(ctx, nil).comments == :read
      {:ok, _} = Sharing.put(scope_for(ctx.owner), ctx.library, "comments", "members")
      assert load!(ctx, nil).comments == :none
      assert load!(ctx, ctx.member).comments == :write
    end

    test "a photo of another library is not found through this one", ctx do
      other = library_fixture(ctx.owner)
      stray = file_fixture(ctx.owner, %{library_uuid: other.uuid})

      assert {:error, :not_found} =
               Details.load(ctx.scope, stray.uuid, scope_for(ctx.owner), "en")
    end

    test "a member is told when a photo has no place, and may add one if an editor", ctx do
      bare = file_fixture(ctx.owner, %{library_uuid: ctx.library.uuid})
      {:ok, details} = Details.load(ctx.scope, bare.uuid, scope_for(ctx.owner), "en")
      assert details.place.view == :missing

      {:ok, details} = Details.load(ctx.scope, bare.uuid, scope_for(ctx.visitor), "en")
      assert details.place == nil
    end
  end

  describe "changes" do
    test "the title and description, in a language of the site", ctx do
      lang = load!(ctx, ctx.owner).lang
      text = %{lang => %{"title" => "Town hall", "description" => "At noon."}}

      assert {:error, _} =
               Details.save_text(ctx.scope, ctx.photo.uuid, text, scope_for(ctx.member))

      assert {:ok, _} = Details.save_text(ctx.scope, ctx.photo.uuid, text, scope_for(ctx.owner))

      shown = load!(ctx, ctx.visitor).text
      assert shown.title == "Town hall"
      assert shown.description == "At noon."
    end

    test "a language the site does not have is not stored", ctx do
      text = %{"xx" => %{"title" => "Nope"}}
      assert {:ok, _} = Details.save_text(ctx.scope, ctx.photo.uuid, text, scope_for(ctx.owner))
      refute Map.has_key?(TestRepo.reload!(ctx.photo).data || %{}, "xx")
    end

    test "the date, by hand, and back", ctx do
      owner = scope_for(ctx.owner)

      assert {:error, _} =
               Details.set_date(
                 ctx.scope,
                 ctx.photo.uuid,
                 "1999-07-04",
                 "06:30",
                 scope_for(ctx.member)
               )

      assert {:error, _} = Details.set_date(ctx.scope, ctx.photo.uuid, "not a date", "", owner)
      assert {:error, _} = Details.set_date(ctx.scope, ctx.photo.uuid, "1700-01-01", "", owner)

      assert {:ok, [_]} =
               Details.set_date(ctx.scope, ctx.photo.uuid, "1999-07-04", "06:30", owner)

      date = load!(ctx, ctx.owner).date
      assert date.local == ~N[1999-07-04 06:30:00]
      assert date.manual?

      assert {:ok, [_]} = Details.reset_date(ctx.scope, ctx.photo.uuid, owner)
      refute load!(ctx, ctx.owner).date.manual?
    end

    test "the place: set with a name, removed, and the camera's back", ctx do
      owner = scope_for(ctx.owner)

      assert {:error, _} =
               Details.set_place(
                 ctx.scope,
                 ctx.photo.uuid,
                 {58.38, 26.72},
                 "Tartu",
                 scope_for(ctx.member)
               )

      assert {:ok, _} =
               Details.set_place(ctx.scope, ctx.photo.uuid, {58.38, 26.72}, "Tartu", owner)

      place = load!(ctx, ctx.owner).place
      assert {place.latitude, place.longitude, place.name} == {58.38, 26.72, "Tartu"}
      assert place.manual?

      assert {:ok, _} = Details.clear_place(ctx.scope, ctx.photo.uuid, owner)
      assert %{view: :missing, manual?: true, exif?: true} = load!(ctx, ctx.owner).place

      assert {:ok, _} = Details.reset_place(ctx.scope, ctx.photo.uuid, owner)
      file = TestRepo.reload!(ctx.photo)
      assert {file.latitude, file.longitude} == {59.437, 24.7453}
      refute ManualLocation.manual?(file)
    end

    test "a photo with no place is offered the place of one taken near then", ctx do
      bare =
        file_fixture(ctx.owner, %{
          library_uuid: ctx.library.uuid,
          taken_at: ~U[2018-07-14 13:00:00Z]
        })

      assert %{latitude: 59.437, longitude: 24.7453} =
               Details.suggest_place(ctx.scope, bare, scope_for(ctx.owner))

      far =
        file_fixture(ctx.owner, %{
          library_uuid: ctx.library.uuid,
          taken_on: ~D[2019-01-01],
          taken_at: ~U[2019-01-01 12:00:00Z]
        })

      assert Details.suggest_place(ctx.scope, far, scope_for(ctx.owner)) == nil
    end
  end

  describe "words" do
    test "dates, zones and a parse that refuses nonsense" do
      assert Details.format_date(~D[1985-03-12]) == "Tuesday, 12 March 1985"
      assert Details.zone(7200) == "UTC+2"
      assert Details.zone(-12_600) == "UTC−3:30"
      assert Details.zone(nil) == nil
      assert Details.parse_date("1985-03-12", "") == {:ok, ~D[1985-03-12]}
      assert Details.parse_date("1985-03-12", "14:05") == {:ok, ~N[1985-03-12 14:05:00]}
      assert Details.parse_date("1985-03-12", "25:99") == {:error, :bad_date}
      assert Details.parse_date(nil, nil) == {:error, :bad_date}
    end
  end

  defp haversine_m(lat1, lon1, lat2, lon2) do
    rad = :math.pi() / 180
    dlat = (lat2 - lat1) * rad
    dlon = (lon2 - lon1) * rad

    a =
      :math.pow(:math.sin(dlat / 2), 2) +
        :math.cos(lat1 * rad) * :math.cos(lat2 * rad) * :math.pow(:math.sin(dlon / 2), 2)

    2 * 6_371_000 * :math.asin(:math.sqrt(a))
  end
end
