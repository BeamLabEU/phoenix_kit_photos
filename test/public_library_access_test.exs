defmodule PhoenixKitPhotos.PublicLibraryAccessTest do
  use PhoenixKitPhotos.DataCase, async: false

  setup do
    owner = user_fixture("audience-owner-#{System.unique_integer([:positive])}@example.com")
    reader = user_fixture("audience-reader-#{System.unique_integer([:positive])}@example.com")
    library = library_fixture(owner)
    file = file_fixture(owner, %{library_uuid: library.uuid})

    %{
      owner: owner,
      reader: reader,
      library: library,
      photo: file,
      partition: {:library, library.uuid}
    }
  end

  test "public libraries expose their timeline to a visitor without an account", ctx do
    ctx.library |> Ecto.Changeset.change(visibility: "site") |> TestRepo.update!()
    assert {:ok, %{total: 1}} = Timeline.index(ctx.partition, nil)
    assert {:ok, %{items: [%{id: id}]}} = Timeline.window(ctx.partition, "2018-07-14", nil)
    assert id == ctx.photo.uuid
  end

  test "account-only audiences require an active signed-in reader", ctx do
    ctx.library
    |> Ecto.Changeset.change(
      visibility: "site",
      settings: %{"public_audience" => "authenticated"}
    )
    |> TestRepo.update!()

    assert {:error, :unauthorized} = Timeline.index(ctx.partition, nil)

    # Core admits an account-only audience once the reader's email is
    # confirmed (`Libraries.authenticated_reader?/1`, unless the site turns
    # confirmation off); the fixture's guest account is not.
    assert {:error, :unauthorized} = Timeline.index(ctx.partition, scope_for(ctx.reader))

    reader =
      ctx.reader
      |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> TestRepo.update!()

    assert {:ok, %{total: 1}} = Timeline.index(ctx.partition, scope_for(reader))
    inactive = %{reader | is_active: false}
    assert {:error, :unauthorized} = Timeline.index(ctx.partition, scope_for(inactive))
  end

  test "private and suspended libraries never admit unrelated readers", ctx do
    assert {:error, :unauthorized} = Timeline.index(ctx.partition, nil)
    assert {:error, :unauthorized} = Timeline.index(ctx.partition, scope_for(ctx.reader))

    ctx.library
    |> Ecto.Changeset.change(visibility: "site", settings: %{"suspended" => true})
    |> TestRepo.update!()

    assert {:error, :unauthorized} = Timeline.index(ctx.partition, nil)
    assert {:ok, %{total: 1}} = Timeline.index(ctx.partition, scope_for(ctx.owner))
  end
end
