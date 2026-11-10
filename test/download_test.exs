defmodule PhoenixKitPhotos.Web.DownloadTest do
  use PhoenixKitPhotos.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias PhoenixKitPhotos.Web.Download

  setup do
    owner = user_fixture("dl-owner-#{System.unique_integer([:positive])}@example.com")
    %{owner: owner, library: library_fixture(owner)}
  end

  defp post_ids(ids, scope) do
    conn(:post, "/photos/download", %{"ids" => Enum.join(ids, ",")})
    |> assign(:phoenix_kit_current_scope, scope)
    |> Download.call([])
  end

  test "someone who may not read the files gets nothing, not an empty archive", ctx do
    file = file_fixture(ctx.owner, %{library_uuid: ctx.library.uuid})
    stranger = user_fixture("dl-x-#{System.unique_integer([:positive])}@example.com")
    assert post_ids([file.uuid], scope_for(stranger)).status == 404
    assert post_ids([file.uuid], nil).status == 404
  end

  test "no ids and nonsense ids are a 404", _ctx do
    assert post_ids([], nil).status == 404
    assert post_ids(["../../etc/passwd"], nil).status == 404
  end

  test "ids that are not the form's string are a 404, not a crash", ctx do
    scope = scope_for(ctx.owner)

    for ids <- [%{"a" => "x"}, ["a", "b"]] do
      conn =
        conn(:post, "/photos/download", %{"ids" => ids})
        |> assign(:phoenix_kit_current_scope, scope)
        |> Download.call([])

      assert conn.status == 404
    end
  end

  test "a file that cannot be read is named in the archive, which still opens", ctx do
    file = file_fixture(ctx.owner, %{library_uuid: ctx.library.uuid})
    conn = post_ids([file.uuid], scope_for(ctx.owner))
    assert conn.status == 200
    assert ["application/zip"] = get_resp_header(conn, "content-type")
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert {:ok, [{~c"Not included.txt", note}]} = :zip.unzip(conn.resp_body, [:memory])
    assert note =~ file.original_file_name
  end

  test "names that collide stay apart, including with a file really called that", ctx do
    same = %{library_uuid: ctx.library.uuid, original_file_name: "IMG.jpg"}
    a = file_fixture(ctx.owner, same)
    b = file_fixture(ctx.owner, same)
    c = file_fixture(ctx.owner, %{same | original_file_name: "IMG (2).jpg"})
    conn = post_ids([a.uuid, b.uuid, c.uuid], scope_for(ctx.owner))
    assert {:ok, [{_name, note}]} = :zip.unzip(conn.resp_body, [:memory])
    names = note |> String.split("\r\n") |> tl()
    assert length(names) == 3
    assert names == Enum.uniq(names)
  end

  test "a visitor gets at most so many files of a public library at once", ctx do
    ctx.library |> Ecto.Changeset.change(visibility: "site") |> TestRepo.update!()
    file = file_fixture(ctx.owner, %{library_uuid: ctx.library.uuid})
    fillers = for _ <- 1..200, do: Ecto.UUID.generate()
    assert post_ids(fillers ++ [file.uuid], nil).status == 404
    assert post_ids([file.uuid], nil).status == 200
  end

  # A session is minted for an account nobody confirmed, so signing up with any address must not
  # be the way past a visitor's limits.
  test "an account nobody confirmed is held to a visitor's limits", ctx do
    ctx.library |> Ecto.Changeset.change(visibility: "site") |> TestRepo.update!()
    file = file_fixture(ctx.owner, %{library_uuid: ctx.library.uuid})
    fillers = for _ <- 1..200, do: Ecto.UUID.generate()
    reader = user_fixture("dl-u-#{System.unique_integer([:positive])}@example.com")

    assert is_nil(reader.confirmed_at)
    assert post_ids(fillers ++ [file.uuid], scope_for(reader)).status == 404

    reader =
      reader
      |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second))
      |> TestRepo.update!()

    assert post_ids(fillers ++ [file.uuid], scope_for(reader)).status == 200
  end
end
