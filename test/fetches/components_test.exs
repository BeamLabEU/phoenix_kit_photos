defmodule PhoenixKitPhotos.Fetches.ComponentsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKitPhotos.Components.{FetchList, LinkFetcher}
  alias PhoenixKitPhotos.Fetches.Fetch

  test "fetch components ignore events belonging to a previous or different reader" do
    user_uuid = Ecto.UUID.generate()
    library_uuid = Ecto.UUID.generate()
    auth = %Scope{user: %User{uuid: user_uuid}}

    foreign = %Fetch{
      uuid: Ecto.UUID.generate(),
      user_uuid: Ecto.UUID.generate(),
      library_uuid: library_uuid,
      status: "probing",
      inserted_at: ~N[2026-11-15 00:00:00]
    }

    for component <- [FetchList, LinkFetcher] do
      {:ok, socket} = component.mount(%Phoenix.LiveView.Socket{})

      socket =
        Phoenix.Component.assign(socket,
          auth: auth,
          library_uuid: library_uuid,
          library_link: nil
        )

      {:ok, unchanged} = component.update(%{fetch_event: {:fetch, foreign}}, socket)
      assert unchanged.assigns.fetches == []

      own = %{foreign | user_uuid: user_uuid}
      {:ok, updated} = component.update(%{fetch_event: {:fetch, own}}, socket)
      assert updated.assigns.fetches == [own]
    end
  end
end
