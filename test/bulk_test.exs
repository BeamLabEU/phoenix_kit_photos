defmodule PhoenixKitPhotos.BulkTest do
  use PhoenixKitPhotos.DataCase, async: false

  defmodule InUse do
    def places(uuids, _ctx),
      do: Enum.map(uuids, &%{file_uuid: &1, label: nil, detail: nil, href: nil})
  end

  defmodule Broken do
    def places(_uuids, _ctx), do: raise("down")
  end

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitPhotos.Bulk

  # Core reads a member's role with `String.to_existing_atom/1`, and no module it loads here
  # names `:viewer`. A host usually does, by chance.
  @viewer :viewer

  setup do
    _ = @viewer
    # Left running by another test file, its name is already taken: that serves just as well.
    _ = start_supervised(PhoenixKit.PubSub.Manager)
    owner = user_fixture("bulk-owner-#{System.unique_integer([:positive])}@example.com")
    stranger = user_fixture("bulk-stranger-#{System.unique_integer([:positive])}@example.com")
    library = library_fixture(owner)
    %{owner: owner, stranger: stranger, library: library, scope: scope_for(owner)}
  end

  defp photo(ctx, attrs \\ %{}) do
    file_fixture(ctx.owner, Map.merge(%{library_uuid: ctx.library.uuid}, attrs))
  end

  defp reload(file), do: TestRepo.get!(StorageFile, file.uuid)

  describe "plan/4" do
    test "writes nothing", ctx do
      file = photo(ctx)
      plan = Bulk.plan(:trash, [file.uuid], ctx.scope)
      assert [%{uuid: uuid}] = plan.files
      assert uuid == file.uuid
      assert is_nil(reload(file).trashed_at)
    end

    test "a file the person may not read looks like one that does not exist", ctx do
      file = photo(ctx)
      plan = Bulk.plan(:trash, [file.uuid], scope_for(ctx.stranger))
      assert plan.files == []
      assert [%{reason: :not_found, name: name}] = plan.refused
      assert name == file.original_file_name

      missing = Bulk.plan(:trash, [Ecto.UUID.generate()], ctx.scope)
      assert [%{reason: :not_found}] = missing.refused
    end

    test "a viewer may read and not change", ctx do
      file = photo(ctx)
      member_fixture(ctx.library, ctx.stranger, "viewer")
      scope = scope_for(ctx.stranger)
      assert [_] = Bulk.plan(:download, [file.uuid], scope).files
      assert [%{reason: :not_allowed}] = Bulk.plan(:trash, [file.uuid], scope).refused

      assert [%{reason: :not_allowed}] =
               Bulk.plan(:tag, [file.uuid], scope, %{"add" => "x"}).refused
    end

    test "a contributor may change what they added, not the rest", ctx do
      mine = file_fixture(ctx.stranger, %{library_uuid: ctx.library.uuid})
      theirs = photo(ctx)
      member_fixture(ctx.library, ctx.stranger, "contributor")
      plan = Bulk.plan(:trash, [mine.uuid, theirs.uuid], scope_for(ctx.stranger))
      assert Enum.map(plan.files, & &1.uuid) == [mine.uuid]
      assert [%{id: id, reason: :not_allowed}] = plan.refused
      assert id == theirs.uuid
    end

    test "nonsense in the list is dropped, doubles count once, and the list has an end", ctx do
      file = photo(ctx)
      plan = Bulk.plan(:trash, [file.uuid, file.uuid, "'; drop table", 7, nil], ctx.scope)
      assert length(plan.files) == 1
      assert plan.refused == []
      many = for _ <- 1..(Bulk.limit() + 5), do: Ecto.UUID.generate()
      assert length(Bulk.plan(:trash, many, ctx.scope).refused) == Bulk.limit()
    end

    test "system-managed children and variants are not files of the timeline", ctx do
      parent = photo(ctx)
      child = photo(ctx, %{parent_file_uuid: parent.uuid})
      managed = photo(ctx, %{system_managed: true, parent_file_uuid: parent.uuid})
      plan = Bulk.plan(:trash, [child.uuid, managed.uuid], ctx.scope)
      assert plan.files == []
    end

    test "a target the person may not add to is no target", ctx do
      file = photo(ctx)
      elsewhere = library_fixture(ctx.stranger)
      plan = Bulk.plan(:copy, [file.uuid], ctx.scope, %{"library" => elsewhere.uuid})
      assert is_nil(plan.target)
      assert [%{reason: :no_target}] = plan.refused
      assert is_nil(Bulk.plan(:copy, [file.uuid], ctx.scope, %{"library" => "nope"}).target)
    end

    test "copying skips the same library and what the target already holds", ctx do
      file = photo(ctx)
      other = library_fixture(ctx.owner)
      twin = file_fixture(ctx.owner, %{library_uuid: other.uuid, file_checksum: "same"})
      same = photo(ctx, %{file_checksum: "same"})
      _ = twin

      assert [%{reason: :same_library}] =
               Bulk.plan(:copy, [file.uuid], ctx.scope, %{"library" => ctx.library.uuid}).refused

      plan = Bulk.plan(:copy, [file.uuid, same.uuid], ctx.scope, %{"library" => other.uuid})
      assert Enum.map(plan.files, & &1.uuid) == [file.uuid]
      assert [%{reason: :already_there}] = plan.refused
    end

    test "files that are not the timeline's are out of reach", ctx do
      pdf = photo(ctx, %{file_type: "document", mime_type: "application/pdf", ext: "pdf"})
      assert [%{reason: :not_found}] = Bulk.plan(:trash, [pdf.uuid], ctx.scope).refused
    end

    test "a library that belongs to a module is no target, whoever asks", ctx do
      file = photo(ctx)

      {:ok, managed} =
        Libraries.create_system_library(
          %{
            name: "Module #{System.unique_integer([:positive])}",
            slug: "module-#{System.unique_integer([:positive])}"
          },
          hidden: true,
          media_listing: :uploaders,
          managed: true
        )

      admin = %{scope_for(ctx.owner) | cached_roles: ["Owner"]}
      plan = Bulk.plan(:copy, [file.uuid], admin, %{"library" => managed.uuid})
      assert is_nil(plan.target)
      assert [%{reason: :no_target}] = plan.refused
    end

    test "an edited image can be copied but not moved", ctx do
      file = photo(ctx)
      file |> Ecto.Changeset.change(edit_revision: 1) |> TestRepo.update!()
      other = library_fixture(ctx.owner)
      params = %{"library" => other.uuid}
      assert [%{reason: :edited}] = Bulk.plan(:move, [file.uuid], ctx.scope, params).refused
      assert [_] = Bulk.plan(:copy, [file.uuid], ctx.scope, params).files
    end

    test "the host's guard keeps what is in use, and failing means no", ctx do
      file = photo(ctx)
      Application.put_env(:phoenix_kit, :file_removal_guard, __MODULE__.InUse)
      on_exit(fn -> Application.delete_env(:phoenix_kit, :file_removal_guard) end)
      assert [%{reason: :in_use}] = Bulk.plan(:trash, [file.uuid], ctx.scope).refused

      Application.put_env(:phoenix_kit, :file_removal_guard, __MODULE__.Broken)
      assert [%{reason: :in_use}] = Bulk.plan(:trash, [file.uuid], ctx.scope).refused
    end

    test "a move needs the right to change the original, a copy only to read it", ctx do
      file = photo(ctx)
      member_fixture(ctx.library, ctx.stranger, "viewer")
      own = library_fixture(ctx.stranger)
      scope = scope_for(ctx.stranger)
      params = %{"library" => own.uuid}
      assert [_] = Bulk.plan(:copy, [file.uuid], scope, params).files
      assert [%{reason: :not_allowed}] = Bulk.plan(:move, [file.uuid], scope, params).refused
    end
  end

  describe "run/2" do
    test "trash and restore are each other's undo", ctx do
      file = photo(ctx)
      result = Bulk.run(Bulk.plan(:trash, [file.uuid], ctx.scope))
      assert result.done == [file.uuid]
      assert reload(file).trashed_at

      assert [%{reason: :trashed}] = Bulk.plan(:trash, [file.uuid], ctx.scope).refused

      result = Bulk.run(Bulk.plan(:restore, [file.uuid], ctx.scope))
      assert result.done == [file.uuid]
      assert is_nil(reload(file).trashed_at)
      assert [%{reason: :not_trashed}] = Bulk.plan(:restore, [file.uuid], ctx.scope).refused
    end

    test "tags are added to what is there and removed by name", ctx do
      file = photo(ctx, %{metadata: %{"tags" => ["sea", "old"], "gps" => "kept"}})
      plan = Bulk.plan(:tag, [file.uuid], ctx.scope, %{"add" => "summer, sea", "remove" => "old"})
      assert plan.add == ["summer", "sea"]
      assert %{done: [_]} = Bulk.run(plan)
      metadata = reload(file).metadata
      assert metadata["tags"] == ["sea", "summer"]
      assert metadata["gps"] == "kept"
    end

    test "one file's failure does not stop the rest", ctx do
      gone = photo(ctx)
      kept = photo(ctx)
      plan = Bulk.plan(:trash, [gone.uuid, kept.uuid], ctx.scope)
      TestRepo.delete!(gone)
      result = Bulk.run(plan)
      assert result.done == [kept.uuid]
      assert [%{id: id, reason: :failed}] = result.failed
      assert id == gone.uuid
    end

    test "says how far it has come", ctx do
      files = for _ <- 1..3, do: photo(ctx)
      me = self()
      plan = Bulk.plan(:trash, Enum.map(files, & &1.uuid), ctx.scope)
      Bulk.run(plan, on_progress: fn done, total -> send(me, {:progress, done, total}) end)
      assert_received {:progress, 1, 3}
      assert_received {:progress, 3, 3}
    end
  end

  describe "what a copy keeps" do
    # `link_copy/3` needs a real donor (an original instance, in a bucket). These look at what
    # `Bulk` does with the copy it gets, so they make one by hand.
    test "a move keeps the date, the place, the tags and the text", ctx do
      file =
        photo(ctx, %{
          taken_at_source: "manual",
          latitude: 59.43,
          longitude: 24.75,
          metadata: %{"tags" => ["sea"], "burn_fingerprint" => "x"}
        })

      file =
        file
        |> Ecto.Changeset.change(data: %{"en" => %{"title" => "Harbour"}})
        |> TestRepo.update!()

      other = library_fixture(ctx.owner)

      copy =
        file_fixture(ctx.owner, %{
          library_uuid: other.uuid,
          taken_on: nil,
          taken_at: nil,
          taken_at_source: nil
        })

      assert {:ok, carried} = Bulk.carry(%{action: :move, auth: ctx.scope}, file, copy)
      assert carried.taken_on == file.taken_on
      assert carried.taken_at_source == "manual"
      assert carried.latitude == 59.43
      assert carried.metadata["tags"] == ["sea"]
      refute Map.has_key?(carried.metadata, "burn_fingerprint")
      assert carried.data["en"]["title"] == "Harbour"
    end

    test "a copy of someone else's photo gets a date, and none of what is theirs", ctx do
      file = photo(ctx, %{latitude: 59.43, metadata: %{"tags" => ["private"]}})
      reader = user_fixture("bulk-reader-#{System.unique_integer([:positive])}@example.com")
      own = library_fixture(reader)

      copy =
        file_fixture(reader, %{
          library_uuid: own.uuid,
          taken_on: nil,
          taken_at: nil,
          taken_at_source: nil
        })

      assert {:ok, carried} =
               Bulk.carry(%{action: :copy, auth: scope_for(reader)}, file, copy)

      assert carried.taken_on == Date.utc_today()
      assert carried.taken_at_source == "inserted_at"
      assert is_nil(carried.latitude)
      refute (carried.metadata || %{})["tags"]
    end
  end

  test "tags/1 cleans what a person typed" do
    assert Bulk.tags(" a, b ,, a ") == ["a", "b"]
    assert Bulk.tags(["x", 1, nil]) == ["x"]
    assert Bulk.tags(nil) == []
    assert Bulk.tags(String.duplicate("x", 99)) == [String.duplicate("x", 60)]
    assert length(Bulk.tags(Enum.map(1..50, &"t#{&1}"))) == 20
  end

  test "action/1 knows only its own names" do
    assert Bulk.action("trash") == :trash
    assert Bulk.action("delete") == nil
    assert Bulk.action("download; rm") == nil
    assert Bulk.action(nil) == nil
  end

  test "a new tag does not void a confirmed trash, and does void a confirmed tagging", ctx do
    file = photo(ctx)
    trash = Bulk.fingerprint(Bulk.plan(:trash, [file.uuid], ctx.scope))
    tag = Bulk.fingerprint(Bulk.plan(:tag, [file.uuid], ctx.scope, %{"add" => "x"}))
    Bulk.run(Bulk.plan(:tag, [file.uuid], ctx.scope, %{"add" => "y"}))
    assert trash == Bulk.fingerprint(Bulk.plan(:trash, [file.uuid], ctx.scope))
    refute tag == Bulk.fingerprint(Bulk.plan(:tag, [file.uuid], ctx.scope, %{"add" => "x"}))
  end

  test "the fingerprint follows the values, not the order", ctx do
    a = photo(ctx)
    b = photo(ctx)
    one = Bulk.fingerprint(Bulk.plan(:trash, [a.uuid, b.uuid], ctx.scope))
    assert one == Bulk.fingerprint(Bulk.plan(:trash, [b.uuid, a.uuid], ctx.scope))
    {:ok, _} = PhoenixKit.Modules.Storage.trash_file(a)
    refute one == Bulk.fingerprint(Bulk.plan(:trash, [a.uuid, b.uuid], ctx.scope))
  end
end
