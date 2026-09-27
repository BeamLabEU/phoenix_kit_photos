defmodule PhoenixKitPhotos.TimelineTest do
  use PhoenixKitPhotos.DataCase, async: true

  describe "base_filters/0" do
    test "excludes the rows that would pollute a naive query" do
      filters = Timeline.base_filters()

      assert filters[:system_managed] == false
      assert filters[:parent_file_uuid] == nil
      assert filters[:trashed_at] == nil
      assert filters[:status] == "active"
      assert filters[:dimensions] == :positive
      assert filters[:file_type] == ["image", "video"]
    end

    test "does not filter edit_state" do
      refute Keyword.has_key?(Timeline.base_filters(), :edit_state)
    end
  end

  describe "window_limit/0" do
    test "caps a window so a fat day cannot flood the socket" do
      assert Timeline.window_limit() == 500
    end
  end

  describe "index/2 and window/3" do
    setup do
      owner = user_fixture("owner-#{System.unique_integer([:positive])}@example.com")
      other = user_fixture("other-#{System.unique_integer([:positive])}@example.com")

      %{
        owner: owner,
        other: other,
        scope: scope_for(owner),
        library: {:library, media_uuid()}
      }
    end

    test "keeps trashed, system, child, non-image and processing rows out", %{
      owner: owner,
      scope: scope,
      library: library
    } do
      kept = file_fixture(owner, %{original_file_name: "kept.jpg"})

      file_fixture(owner, %{original_file_name: "trash.jpg", trashed_at: ~U[2018-07-15 00:00:00Z]})

      file_fixture(owner, %{
        original_file_name: "tile.jpg",
        system_managed: true,
        parent_file_uuid: kept.uuid
      })

      file_fixture(owner, %{
        original_file_name: "child.jpg",
        parent_file_uuid: kept.uuid
      })

      file_fixture(owner, %{
        original_file_name: "notes.pdf",
        file_type: "document",
        mime_type: "application/pdf",
        ext: "pdf"
      })

      file_fixture(owner, %{original_file_name: "soon.jpg", status: "processing"})

      file_fixture(owner, %{original_file_name: "flat.jpg", width: 0, height: 0})

      pending = file_fixture(owner, %{original_file_name: "edit.jpg", edit_state: "pending"})

      assert {:ok, index} = Timeline.index(library, scope)
      assert index.total == 2
      assert [%{id: "2018-07", count: 2}] = index.sections

      assert {:ok, window} = Timeline.window(library, "2018-07-14", scope)
      assert Enum.sort(Enum.map(window.items, & &1.id)) == Enum.sort([kept.uuid, pending.uuid])
    end

    test "a late-evening photo stays in the month of taken_on", %{
      owner: owner,
      scope: scope,
      library: library
    } do
      file_fixture(owner, %{
        original_file_name: "late.jpg",
        taken_on: ~D[2018-07-31],
        taken_at: ~U[2018-08-01 06:30:00Z]
      })

      assert {:ok, %{sections: [%{id: "2018-07"}]}} = Timeline.index(library, scope)
      assert {:ok, %{items: [%{id: _}]}} = Timeline.window(library, "2018-07-31", scope)
      assert {:ok, %{items: []}} = Timeline.window(library, "2018-08-01", scope)
    end

    test "a day over the cap is subdivided without losing items", %{
      owner: owner,
      scope: scope,
      library: library
    } do
      for n <- 0..500 do
        file_fixture(owner, %{
          original_file_name: "n#{n}.jpg",
          taken_at: DateTime.add(~U[2018-07-14 00:00:00Z], n, :second)
        })
      end

      assert {:ok, %{items: items}} = Timeline.window(library, "2018-07-14", scope)
      assert length(items) == 500
      assert hd(items).taken_at == ~U[2018-07-14 00:00:00Z]
      assert {:ok, %{sections: [section]}} = Timeline.index(library, scope)

      assert section.days_list == [
               %{id: "2018-07-14", count: 500},
               %{id: "2018-07-14:500", count: 1}
             ]

      assert {:ok, %{items: [last]}} = Timeline.window(library, "2018-07-14:500", scope)
      assert last.taken_at == ~U[2018-07-14 00:08:20Z]
      refute last.id in Enum.map(items, & &1.id)
    end

    test "another user does not see files they did not upload", %{
      owner: owner,
      other: other,
      library: library
    } do
      file_fixture(owner, %{original_file_name: "mine.jpg"})

      assert {:ok, %{total: 0}} = Timeline.index(library, scope_for(other))
    end

    test "an owner sees every file in the library", %{
      owner: owner,
      other: other,
      library: library
    } do
      file_fixture(owner, %{original_file_name: "mine.jpg"})
      file_fixture(other, %{original_file_name: "theirs.jpg"})

      admin = scope_for(owner, ["Owner"])
      assert {:ok, %{total: 2}} = Timeline.index(library, admin)
    end

    test "an empty library says so, and a processing upload says it is still working", %{
      scope: scope,
      library: library,
      owner: owner
    } do
      assert {:ok, %{total: 0, state: :empty}} = Timeline.index(library, scope)

      file_fixture(owner, %{
        original_file_name: "soon.jpg",
        status: "processing",
        taken_on: nil,
        taken_at: nil
      })

      assert {:ok, %{total: 0, state: :processing}} = Timeline.index(library, scope)
    end

    test "members read shared files, nonmembers only their own uploads", %{
      owner: owner,
      other: other
    } do
      library = library_fixture(owner)
      file = file_fixture(owner, %{library_uuid: library.uuid})
      own = file_fixture(other, %{library_uuid: library.uuid})
      scope = scope_for(other)
      partition = {:library, library.uuid}
      assert {:ok, %{items: [%{id: id}]}} = Timeline.window(partition, "2018-07-14", scope)
      assert id == own.uuid
      refute Libraries.can?(scope, file, :read)
      member_fixture(library, other)
      assert Libraries.role(library, other.uuid) == :viewer
      assert Libraries.can?(scope, file, :read)
      assert {:ok, %{total: 2}} = Timeline.index(partition, scope)
      assert {:ok, %{items: items}} = Timeline.window(partition, "2018-07-14", scope)
      assert length(items) == 2
    end

    test "private libraries receive expiring variant URLs", %{owner: owner, scope: scope} do
      alias PhoenixKit.Modules.Storage.URLSigner
      library = owner |> library_fixture() |> variants_fixture()
      file_fixture(owner, %{library_uuid: library.uuid})

      assert {:ok, %{items: [item]}} =
               Timeline.window({:library, library.uuid}, "2018-07-14", scope)

      for url <- [item.thumb, item.preview] do
        assert is_binary(url)
        [_, _, file_uuid, variant, token] = URI.parse(url).path |> String.split("/")
        assert URLSigner.private_token?(token)
        assert :ok = URLSigner.verify_private_token(file_uuid, variant, token)
      end
    end

    test "no configured variants never falls back to an original", %{owner: owner, scope: scope} do
      alias PhoenixKit.Modules.Storage.VariantSet
      library = library_fixture(owner)
      set = TestRepo.insert!(%VariantSet{name: "Empty #{library.uuid}"})
      library |> Ecto.Changeset.change(variant_set_uuid: set.uuid) |> TestRepo.update!()
      file_fixture(owner, %{library_uuid: library.uuid})

      assert {:ok, %{items: [%{thumb: nil, preview: nil}]}} =
               Timeline.window({:library, library.uuid}, "2018-07-14", scope)
    end

    test "backfill state only considers visible files in this library", %{
      owner: owner,
      other: other,
      scope: scope,
      library: partition
    } do
      file_fixture(other, %{taken_on: nil})
      assert {:ok, %{state: :empty}} = Timeline.index(partition, scope)
      file_fixture(owner, %{taken_on: nil})
      assert {:ok, %{state: :backfill}} = Timeline.index(partition, scope)
      private = library_fixture(owner)
      assert {:ok, %{state: :empty}} = Timeline.index({:library, private.uuid}, scope)
    end

    test "malformed window identifiers are refused", %{scope: scope, library: library} do
      for id <- ["nonsense", "2018-07-14:-500", "2018-07-14:1", "2018-07-14:500:0", nil] do
        assert {:error, :not_found} = Timeline.window(library, id, scope)
      end
    end

    test "viewer checks ownership, library and trash status", %{
      owner: owner,
      other: other,
      scope: scope,
      library: library
    } do
      file = file_fixture(owner, %{})
      assert {:ok, %{file_uuid: id}} = Timeline.viewer_file(library, file.uuid, scope)
      assert id == file.uuid
      assert {:error, :not_found} = Timeline.viewer_file(library, file.uuid, scope_for(other))
      private = library_fixture(owner)

      assert {:error, :not_found} =
               Timeline.viewer_file({:library, private.uuid}, file.uuid, scope)

      assert {:error, :not_found} = Timeline.viewer_file(library, "bad-uuid", scope)
      file |> Ecto.Changeset.change(trashed_at: DateTime.utc_now(:second)) |> TestRepo.update!()
      assert {:error, :not_found} = Timeline.viewer_file(library, file.uuid, scope)
    end

    test "completed instance checksums version the variant URLs", %{owner: owner, scope: scope} do
      alias PhoenixKit.Modules.Storage.FileInstance
      library = owner |> library_fixture() |> variants_fixture()
      file = file_fixture(owner, %{library_uuid: library.uuid})
      checksum = String.duplicate("a", 64)

      TestRepo.insert!(%FileInstance{
        file_uuid: file.uuid,
        variant_name: "thumbnail",
        file_name: "thumb.jpg",
        mime_type: "image/jpeg",
        ext: "jpg",
        size: 123,
        checksum: checksum,
        processing_status: "completed"
      })

      assert {:ok, %{items: [item]}} =
               Timeline.window({:library, library.uuid}, "2018-07-14", scope)

      assert URI.decode_query(URI.parse(item.thumb).query)["v"] == String.slice(checksum, 0, 16)
    end

    test "the 10k benchmark fixture has full counts and bounded windows", %{
      owner: owner,
      scope: scope
    } do
      library = library_fixture(owner)
      PhoenixKitPhotos.SyntheticLibrary.seed!(TestRepo, owner, library)

      assert {:ok, %{total: 10_000, sections: sections}} =
               Timeline.index({:library, library.uuid}, scope)

      assert hd(sections).count == 1200
      assert Enum.map(hd(sections).days_list, & &1.count) == [500, 500, 200]

      assert Enum.all?(sections, fn section ->
               Enum.all?(section.days_list, &(&1.count <= 500))
             end)
    end

    test "a missing library is not found", %{scope: scope} do
      assert {:error, :not_found} =
               Timeline.index({:library, "00000000-0000-7000-8000-000000000099"}, scope)
    end
  end

  describe "group_days/1" do
    test "labels the month from taken_on" do
      [section] =
        Timeline.group_days([
          %{taken_on: ~D[2018-07-31], count: 1, sum_aspect: 1.5},
          %{taken_on: ~D[2018-07-01], count: 2, sum_aspect: 2.0}
        ])

      assert section.id == "2018-07"
      assert section.label == "July 2018"
      assert section.count == 3
      assert section.days == 2
      assert section.days_list == [%{id: "2018-07-01", count: 2}, %{id: "2018-07-31", count: 1}]
      assert_in_delta section.sum_aspect, 3.5, 0.001
    end
  end
end
