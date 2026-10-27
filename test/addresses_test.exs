defmodule PhoenixKitPhotos.AddressesTest do
  @moduledoc """
  What a host needs to give photos addresses: the short code in every slide, the position of a
  photo in the timeline, and the component's `photo_path` / `library_path` and `push_view/5`.
  """
  use PhoenixKitPhotos.DataCase, async: false
  import Phoenix.LiveViewTest


  @endpoint PhoenixKitPhotos.TestEndpoint

  describe "Timeline.position/3" do
    setup do
      owner = user_fixture("pos-#{System.unique_integer([:positive])}@example.com")
      library = library_fixture(owner)

      %{
        owner: owner,
        library: library,
        partition: {:library, library.uuid},
        scope: scope_for(owner)
      }
    end

    defp photo(owner, library, at, extra \\ %{}) do
      file_fixture(
        owner,
        Map.merge(
          %{
            library_uuid: library.uuid,
            taken_at: at,
            taken_on: DateTime.to_date(at)
          },
          extra
        )
      )
    end

    test "counts the photos before it, across days", ctx do
      a = photo(ctx.owner, ctx.library, ~U[2018-07-14 10:00:00Z])
      b = photo(ctx.owner, ctx.library, ~U[2018-07-14 11:00:00Z])
      c = photo(ctx.owner, ctx.library, ~U[2018-08-01 09:00:00Z])

      assert {:ok, 0} = Timeline.position(ctx.partition, a.uuid, ctx.scope)
      assert {:ok, 1} = Timeline.position(ctx.partition, b.uuid, ctx.scope)
      assert {:ok, 2} = Timeline.position(ctx.partition, c.uuid, ctx.scope)
    end

    test "agrees with the order the windows give, ties broken by uuid", ctx do
      at = ~U[2018-07-14 10:00:00Z]
      files = for _ <- 1..4, do: photo(ctx.owner, ctx.library, at)
      {:ok, %{items: items}} = Timeline.window(ctx.partition, "2018-07-14", ctx.scope)

      for {item, index} <- Enum.with_index(items) do
        assert {:ok, ^index} = Timeline.position(ctx.partition, item.id, ctx.scope)
      end

      assert Enum.sort(Enum.map(files, & &1.uuid)) == Enum.map(items, & &1.id)
    end

    test "a photo is not found in another library, when it is not the viewer's, or when it is no uuid",
         ctx do
      other_library = library_fixture(ctx.owner)
      elsewhere = photo(ctx.owner, other_library, ~U[2018-07-14 10:00:00Z])
      mine = photo(ctx.owner, ctx.library, ~U[2018-07-14 10:00:00Z])

      stranger =
        scope_for(user_fixture("stranger-#{System.unique_integer([:positive])}@example.com"))

      assert {:error, :not_found} = Timeline.position(ctx.partition, elsewhere.uuid, ctx.scope)
      assert {:error, :not_found} = Timeline.position(ctx.partition, mine.uuid, stranger)

      assert {:error, :not_found} =
               Timeline.position(ctx.partition, Ecto.UUID.generate(), ctx.scope)

      assert {:error, _} = Timeline.position(ctx.partition, "nope", ctx.scope)
    end
  end

  describe "slides" do
    test "carry the file's short code" do
      owner = user_fixture("code-#{System.unique_integer([:positive])}@example.com")
      library = library_fixture(owner)
      file = file_fixture(owner, %{library_uuid: library.uuid})
      assert is_binary(file.short_code)

      assert {:ok, [%{id: id, code: code}]} =
               Timeline.slides(
                 {:library, library.uuid},
                 "2018-07-14",
                 0,
                 12,
                 700,
                 scope_for(owner)
               )

      assert {id, code} == {file.uuid, file.short_code}
    end
  end

  describe "the component" do
    setup do
      start_supervised!({Phoenix.PubSub, name: PhoenixKitPhotos.TestPubSub})
      start_supervised!(PhoenixKitPhotos.TestEndpoint)
      start_supervised!(PhoenixKit.PubSub.Manager)
      %{user: user_fixture("cmp-#{System.unique_integer([:positive])}@example.com")}
    end

    defp host(user, session \\ %{}) do
      {:ok, view, html} =
        live_isolated(Phoenix.ConnTest.build_conn(), PhoenixKitPhotos.TestLive,
          session:
            Map.merge(
              %{"scope" => scope_for(user), "library" => {:library, media_uuid()}},
              session
            )
        )

      {view, html}
    end

    test "puts the addresses on the page for the hook", %{user: user} do
      {_view, html} =
        host(user, %{"photo_path" => "/anna/private/p/:code", "library_path" => "/anna/private"})

      assert html =~ ~s(data-photo-path="/anna/private/p/:code")
      assert html =~ ~s(data-library-path="/anna/private")
    end

    test "puts nothing on the page without them", %{user: user} do
      {_view, html} = host(user)
      refute html =~ "data-photo-path"
      refute html =~ "data-library-path"
    end

    test "refuses an address that is not a path on the site, or a photo address with no :code", %{
      user: user
    } do
      for bad <- [
            "https://evil.example/p/:code",
            "//evil.example/p/:code",
            "/a b/:code",
            "javascript:alert(1)",
            "/\\evil/:code"
          ] do
        {_view, html} = host(user, %{"photo_path" => bad, "library_path" => bad})
        refute html =~ "data-photo-path", "accepted #{inspect(bad)}"
        refute html =~ "data-library-path", "accepted #{inspect(bad)}"
      end

      {_view, html} =
        host(user, %{"photo_path" => "/anna/private/p/x", "library_path" => "/anna/private"})

      refute html =~ "data-photo-path"
      assert html =~ "data-library-path"
    end

    test "push_view/5 tells the hook which photo the address names, and where it is", %{
      user: user
    } do
      a = file_fixture(user, %{taken_at: ~U[2018-07-14 10:00:00Z], taken_on: ~D[2018-07-14]})
      b = file_fixture(user, %{taken_at: ~U[2018-07-14 11:00:00Z], taken_on: ~D[2018-07-14]})
      {view, _html} = host(user)

      send(view.pid, {:view, b.uuid})
      b_uuid = b.uuid
      assert_push_event(view, "timeline:test-timeline:view", %{id: ^b_uuid, global: 1})

      send(view.pid, {:view, a.uuid})
      a_uuid = a.uuid
      assert_push_event(view, "timeline:test-timeline:view", %{id: ^a_uuid, global: 0})
    end

    test "push_view/5 with no photo, or one the viewer may not read, closes the viewer", %{
      user: user
    } do
      other = user_fixture("owner-#{System.unique_integer([:positive])}@example.com")
      theirs = library_fixture(other)
      file = file_fixture(other, %{library_uuid: theirs.uuid})
      {view, _html} = host(user)

      send(view.pid, {:view, nil})
      assert_push_event(view, "timeline:test-timeline:view", %{id: nil, global: nil})

      send(view.pid, {:view, file.uuid})
      assert_push_event(view, "timeline:test-timeline:view", %{id: nil, global: nil})
    end
  end
end
