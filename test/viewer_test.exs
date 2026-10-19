defmodule PhoenixKitPhotos.ViewerTest do
  use PhoenixKitPhotos.DataCase, async: false
  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKitPhotos.Viewer

  @endpoint PhoenixKitPhotos.TestEndpoint

  setup do
    owner = user_fixture("owner-#{System.unique_integer([:positive])}@example.com")
    other = user_fixture("other-#{System.unique_integer([:positive])}@example.com")
    library = library_fixture(owner)

    on_exit(fn -> Application.delete_env(:phoenix_kit_photos, :default_viewer) end)

    %{owner: owner, other: other, library: library, scope: scope_for(owner)}
  end

  describe "choosing" do
    test "offers the swipe viewer and the classic one" do
      assert [{"photoswipe", _}, {"classic", _}] = Viewer.options()
    end

    test "a library follows the default until it chooses, and the default is the swipe viewer",
         %{library: library} do
      assert Viewer.default() == "photoswipe"
      assert Viewer.for_library(library) == "photoswipe"
      assert Viewer.chosen(library) == nil
    end

    test "the default can be set by the host, and only to a viewer that is offered", %{
      library: library
    } do
      Application.put_env(:phoenix_kit_photos, :default_viewer, "classic")
      assert Viewer.default() == "classic"
      assert Viewer.for_library(library) == "classic"

      Application.put_env(:phoenix_kit_photos, :default_viewer, "nonsense")
      assert Viewer.default() == "photoswipe"
    end

    test "a library's own choice wins over the default, either way", %{
      library: library,
      scope: scope
    } do
      assert {:ok, library} = Viewer.put(scope, library, "classic")
      assert Viewer.for_library(library) == "classic"
      assert Viewer.for_library(library.uuid) == "classic"
      assert Viewer.chosen(library) == "classic"

      Application.put_env(:phoenix_kit_photos, :default_viewer, "classic")
      assert {:ok, library} = Viewer.put(scope, library, "photoswipe")
      assert Viewer.for_library(library) == "photoswipe"

      assert {:ok, library} = Viewer.put(scope, library, nil)
      assert Viewer.chosen(library) == nil
      assert Viewer.for_library(library) == "classic"
    end

    test "a name stored that is not offered (the snap engine, a retired one) is the default", %{
      library: library
    } do
      {:ok, library} = Libraries.put_setting(library, :viewer, "snap")
      assert Libraries.setting(library, :viewer) == "snap"
      assert Viewer.for_library(library) == "photoswipe"
      assert Viewer.chosen(library) == nil
    end

    test "Media is a library like another" do
      assert Viewer.for_library(nil) == Viewer.for_library(Libraries.media_uuid())
    end

    test "the timeline's `pager` for each viewer" do
      assert Viewer.pager("classic") == false
      assert Viewer.pager("photoswipe") == "photoswipe"
      assert Viewer.pager("anything else") == "photoswipe"
    end
  end

  describe "who may choose" do
    test "the owner of a user library, not a stranger, a viewer or a visitor", %{
      owner: owner,
      other: other,
      library: library,
      scope: scope
    } do
      assert Viewer.can_set?(scope, library)
      refute Viewer.can_set?(scope_for(other), library)
      refute Viewer.can_set?(nil, library)

      member_fixture(library, other, "viewer")
      refute Viewer.can_set?(scope_for(other), library)

      manager = user_fixture("manager-#{System.unique_integer([:positive])}@example.com")
      member_fixture(library, manager, "manager")
      assert Viewer.can_set?(scope_for(manager), library)

      contributor = user_fixture("contrib-#{System.unique_integer([:positive])}@example.com")
      member_fixture(library, contributor, "contributor")
      refute Viewer.can_set?(scope_for(contributor), library)

      assert owner.uuid
    end

    test "for Media, the site's admins and nobody else", %{scope: scope} do
      media = Libraries.get_library(Libraries.media_uuid())
      refute Viewer.can_set?(scope, media)

      assert Viewer.can_set?(
               scope_for(
                 user_fixture("admin-#{System.unique_integer([:positive])}@example.com"),
                 ["Admin"]
               ),
               media
             )
    end

    test "not for a trashed library", %{library: library, scope: scope} do
      trashed = %{library | trashed_at: DateTime.utc_now(:second)}
      refute Viewer.can_set?(scope, trashed)
    end

    test "put/3 refuses someone who may not, and a name that is not offered", %{
      other: other,
      library: library,
      scope: scope
    } do
      assert {:error, :not_allowed} = Viewer.put(scope_for(other), library, "classic")
      assert {:error, :not_allowed} = Viewer.put(nil, library, "classic")
      assert {:error, :unknown_viewer} = Viewer.put(scope, library, "snap")
      assert {:error, :unknown_viewer} = Viewer.put(scope, library, "")
      assert Viewer.chosen(library) == nil
    end
  end

  describe "the picker" do
    defp mount_picker(scope, library) do
      {:ok, view, _html} =
        live_isolated(Phoenix.ConnTest.build_conn(), PhoenixKitPhotos.ViewerLive,
          session: %{"scope" => scope, "library" => library.uuid}
        )

      view
    end

    setup do
      start_supervised!({Phoenix.PubSub, name: PhoenixKitPhotos.TestPubSub})
      start_supervised!(PhoenixKitPhotos.TestEndpoint)
      :ok
    end

    test "shows the choices, the default one selected, to the owner", %{
      library: library,
      scope: scope
    } do
      html = library |> then(&mount_picker(scope, &1)) |> render()
      assert html =~ "Swipe viewer"
      assert html =~ "Classic viewer"
      assert html =~ "Default (Swipe viewer)"
      assert html =~ ~r/<option[^>]*value=""[^>]*selected/
    end

    test "shows nothing to someone who may not choose", %{other: other, library: library} do
      refute library |> then(&mount_picker(scope_for(other), &1)) |> render() =~ "<select"
    end

    test "saves the choice, and tells the page", %{library: library, scope: scope} do
      view = mount_picker(scope, library)

      view |> element("#test-viewer-form") |> render_change(%{"viewer" => "classic"})
      assert Viewer.chosen(Libraries.get_library(library.uuid)) == "classic"
      assert :sys.get_state(view.pid).socket.assigns.changed == [library.uuid]
      assert render(view) =~ ~r/<option[^>]*value="classic"[^>]*selected/

      view |> element("#test-viewer-form") |> render_change(%{"viewer" => ""})
      assert Viewer.chosen(Libraries.get_library(library.uuid)) == nil
    end

    test "refuses a name that is not offered, and says so", %{library: library, scope: scope} do
      view = mount_picker(scope, library)
      html = view |> element("#test-viewer-form") |> render_change(%{"viewer" => "snap"})
      assert html =~ "Could not save the viewer"
      assert Viewer.chosen(Libraries.get_library(library.uuid)) == nil
    end
  end
end
