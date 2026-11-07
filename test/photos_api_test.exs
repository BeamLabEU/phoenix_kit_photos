defmodule PhoenixKitPhotos.APITest do
  use PhoenixKitPhotos.DataCase, async: false

  alias PhoenixKit.API.ToolLint
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitPhotos.API

  setup do
    start_supervised!(PhoenixKit.PubSub.Manager)
    owner = user_fixture("api-owner-#{System.unique_integer([:positive])}@example.com")
    stranger = user_fixture("api-stranger-#{System.unique_integer([:positive])}@example.com")
    library = library_fixture(owner)
    %{owner: owner, stranger: stranger, library: library, ctx: ctx(owner)}
  end

  defp ctx(user, dry_run? \\ false), do: %{scope: scope_for(user), dry_run?: dry_run?}

  defp photo(setup, attrs \\ %{}) do
    file_fixture(setup.owner, Map.merge(%{library_uuid: setup.library.uuid}, attrs))
  end

  test "the tools pass core's lint" do
    assert ToolLint.check_tools(API.tools()) == :ok
  end

  describe "photos.find_files" do
    test "narrows by date, kind, tag and name", setup do
      july = photo(setup, %{original_file_name: "beach_01.jpg", metadata: %{"tags" => ["sea"]}})

      video =
        photo(setup, %{
          file_type: "video",
          mime_type: "video/mp4",
          ext: "mp4",
          taken_on: ~D[2019-01-02],
          taken_at: ~U[2019-01-02 10:00:00Z]
        })

      find = fn filters ->
        {:ok, %{"files" => files}} =
          API.find_files(Map.put(filters, "library", setup.library.uuid), setup.ctx)

        Enum.map(files, & &1["id"])
      end

      assert find.(%{}) == [july.uuid, video.uuid]
      assert find.(%{"kind" => "video"}) == [video.uuid]
      assert find.(%{"to" => "2018-12-31"}) == [july.uuid]
      assert find.(%{"from" => "2019-01-01"}) == [video.uuid]
      assert find.(%{"tag" => "sea"}) == [july.uuid]
      assert find.(%{"tag" => "lake"}) == []
      assert find.(%{"name" => "BEACH"}) == [july.uuid]
      assert find.(%{"name" => "%"}) == []
    end

    test "pages to the end without repeating a file", setup do
      files =
        for day <- 1..5 do
          date = Date.new!(2020, 1, day)
          photo(setup, %{taken_on: date, taken_at: DateTime.new!(date, ~T[12:00:00])})
        end

      input = %{"library" => setup.library.uuid, "limit" => 2}
      {:ok, one} = API.find_files(input, setup.ctx)
      {:ok, two} = API.find_files(Map.put(input, "after", one["next"]), setup.ctx)
      {:ok, three} = API.find_files(Map.put(input, "after", two["next"]), setup.ctx)
      seen = Enum.flat_map([one, two, three], & &1["files"]) |> Enum.map(& &1["id"])
      assert seen == Enum.map(files, & &1.uuid)
      assert is_nil(three["next"])
    end

    test "a bad date says so, a library the key's owner cannot open does not exist", setup do
      input = %{"library" => setup.library.uuid, "from" => "tomorrow"}
      assert {:error, :validation_failed, _, _} = API.find_files(input, setup.ctx)

      assert {:error, :not_found, _, _} =
               API.find_files(%{"library" => setup.library.uuid}, ctx(setup.stranger))
    end
  end

  describe "the write tools" do
    test "a dry run writes nothing and names the files", setup do
      file = photo(setup)
      dry = ctx(setup.owner, true)
      assert {:preview, preview, fingerprint} = API.trash_files(%{"ids" => [file.uuid]}, dry)
      assert [%{"id" => id}] = preview["rows"]
      assert id == file.uuid
      assert is_binary(fingerprint)
      assert is_nil(TestRepo.get!(StorageFile, file.uuid).trashed_at)
    end

    test "the fingerprint changes when a touched value changes, and only then", setup do
      file = photo(setup)
      dry = ctx(setup.owner, true)
      input = %{"ids" => [file.uuid]}
      {:preview, _, before} = API.tag_files(Map.put(input, "add", ["x"]), dry)
      {:preview, _, same} = API.tag_files(Map.put(input, "add", ["x"]), dry)
      assert before == same

      {:ok, _} = API.tag_files(Map.put(input, "add", ["y"]), setup.ctx)
      {:preview, _, changed} = API.tag_files(Map.put(input, "add", ["x"]), dry)
      refute before == changed
    end

    test "acts for the key's owner only: a stranger's file is skipped", setup do
      file = photo(setup)
      assert {:ok, result} = API.trash_files(%{"ids" => [file.uuid]}, ctx(setup.stranger))
      assert result["done"] == []
      assert [%{"id" => id, "reason" => "not_found"}] = result["skipped"]
      assert id == file.uuid
      assert is_nil(TestRepo.get!(StorageFile, file.uuid).trashed_at)
    end

    test "copying to a library nobody may add to is refused outright", setup do
      file = photo(setup)
      elsewhere = library_fixture(setup.stranger)

      assert {:error, :not_found, _, _} =
               API.copy_files(%{"ids" => [file.uuid], "library" => elsewhere.uuid}, setup.ctx)
    end
  end
end
