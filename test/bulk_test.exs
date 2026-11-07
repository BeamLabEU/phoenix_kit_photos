defmodule PhoenixKitPhotos.BulkTest do
  use PhoenixKitPhotos.DataCase, async: false

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitPhotos.Bulk

  # Core reads a member's role with `String.to_existing_atom/1`, and no module it loads here
  # names `:viewer`. A host usually does, by chance.
  @viewer :viewer

  setup do
    _ = @viewer
    start_supervised!(PhoenixKit.PubSub.Manager)
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

    test "says how far it has come", ctx do
      files = for _ <- 1..3, do: photo(ctx)
      me = self()
      plan = Bulk.plan(:trash, Enum.map(files, & &1.uuid), ctx.scope)
      Bulk.run(plan, on_progress: fn done, total -> send(me, {:progress, done, total}) end)
      assert_received {:progress, 1, 3}
      assert_received {:progress, 3, 3}
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

  test "the fingerprint follows the values, not the order", ctx do
    a = photo(ctx)
    b = photo(ctx)
    one = Bulk.fingerprint(Bulk.plan(:trash, [a.uuid, b.uuid], ctx.scope))
    assert one == Bulk.fingerprint(Bulk.plan(:trash, [b.uuid, a.uuid], ctx.scope))
    {:ok, _} = PhoenixKit.Modules.Storage.trash_file(a)
    refute one == Bulk.fingerprint(Bulk.plan(:trash, [a.uuid, b.uuid], ctx.scope))
  end
end
