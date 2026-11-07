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

  test "a file that cannot be read leaves an archive that still opens", ctx do
    file = file_fixture(ctx.owner, %{library_uuid: ctx.library.uuid})
    conn = post_ids([file.uuid], scope_for(ctx.owner))
    assert conn.status == 200
    assert ["application/zip"] = get_resp_header(conn, "content-type")
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert {:ok, []} = :zip.unzip(conn.resp_body, [:memory])
  end
end
