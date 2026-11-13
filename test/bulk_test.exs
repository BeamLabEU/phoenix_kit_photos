defmodule PhoenixKitPhotos.BulkTest do
  use PhoenixKitPhotos.DataCase, async: false

  defmodule InUse do
    def places(uuids, _ctx),
      do: Enum.map(uuids, &%{file_uuid: &1, label: nil, detail: nil, href: nil})
  end

  defmodule Broken do
    def places(_uuids, _ctx), do: raise("down")
  end

  defmodule Shouting do
    def places(uuids, _ctx), do: Enum.map(uuids, &%{file_uuid: String.upcase(&1)})
  end

  defmodule Stranger do
    def places(_uuids, _ctx), do: [%{file_uuid: Ecto.UUID.generate()}]
  end

  defmodule Slow do
    def places(_uuids, _ctx), do: Process.sleep(:infinity)
  end

  alias PhoenixKit.Modules.Storage
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

    @tag :capture_log
    test "the guard's uuids match in any case, and an answer about other files means no", ctx do
      file = photo(ctx)
      on_exit(fn -> Application.delete_env(:phoenix_kit, :file_removal_guard) end)

      Application.put_env(:phoenix_kit, :file_removal_guard, __MODULE__.Shouting)
      assert [%{reason: :in_use}] = Bulk.plan(:trash, [file.uuid], ctx.scope).refused

      Application.put_env(:phoenix_kit, :file_removal_guard, __MODULE__.Stranger)
      assert [%{reason: :in_use}] = Bulk.plan(:trash, [file.uuid], ctx.scope).refused
    end

    @tag :capture_log
    test "a guard that does not answer in time means no, and does not hold the caller", ctx do
      file = photo(ctx)
      Application.put_env(:phoenix_kit, :file_removal_guard, __MODULE__.Slow)
      Application.put_env(:phoenix_kit, :file_removal_guard_timeout, 50)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit, :file_removal_guard)
        Application.delete_env(:phoenix_kit, :file_removal_guard_timeout)
      end)

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

  describe "stacks" do
    alias PhoenixKit.Modules.Storage.Stacks

    defp pages(ctx, n) do
      for i <- 1..n do
        photo(ctx, %{
          original_file_name: "page #{i}.jpg",
          taken_at: DateTime.add(~U[2018-07-14 10:00:00Z], i, :minute)
        })
      end
    end

    test "a chosen stack means all of its files, in its order, out of the trash", ctx do
      [p1, p2, p3] = pages(ctx, 3)
      single = photo(ctx)
      {:ok, _} = Stacks.create([p3.uuid, p1.uuid, p2.uuid], ctx.scope)
      {:ok, _} = Storage.trash_file(p2)

      assert Bulk.whole_stacks([single.uuid, p1.uuid], :trash, ctx.scope) ==
               [single.uuid, p1.uuid, p3.uuid]

      assert Bulk.whole_stacks([p1.uuid], :restore, ctx.scope) == [p1.uuid, p2.uuid, p3.uuid]

      # A stack's one address; stacking and unstacking take stacks as they are.
      for action <- [:links, :stack, :unstack] do
        assert Bulk.whole_stacks([p1.uuid], action, ctx.scope) == [p1.uuid]
      end

      # Only what the person may read comes along.
      assert Bulk.whole_stacks([p1.uuid], :download, scope_for(ctx.stranger)) == [p1.uuid]
    end

    test "stack and unstack, for someone who may change the files", ctx do
      [p1, p2, p3] = pages(ctx, 3)
      ids = [p2.uuid, p1.uuid, p3.uuid]

      refused = Bulk.plan(:stack, ids, scope_for(ctx.stranger), %{"title" => "x"})
      assert refused.files == []

      plan = Bulk.plan(:stack, ids, ctx.scope, %{"title" => "  Lease  "})
      assert plan.title == "Lease"
      assert %{done: done, failed: []} = Bulk.run(plan)
      assert length(done) == 3

      stack = Stacks.get(reload(p1).stack_uuid)
      assert stack.title == "Lease"
      assert Enum.map(Stacks.files(stack.uuid), & &1.uuid) == [p1.uuid, p2.uuid, p3.uuid]

      single = photo(ctx)
      plan = Bulk.plan(:unstack, [p1.uuid, single.uuid], ctx.scope)
      assert [%{reason: :not_stacked}] = plan.refused
      assert %{done: undone} = Bulk.run(plan)
      assert Enum.sort(undone) == Enum.sort([p1.uuid, p2.uuid, p3.uuid])
      assert is_nil(reload(p2).stack_uuid)
    end

    test "a stack with more photos and no title given keeps its title", ctx do
      [p1, p2, p3] = pages(ctx, 3)
      {:ok, _} = Stacks.create([p1.uuid, p2.uuid], ctx.scope, %{title: "Lease"})

      # The dialog's title box left empty.
      plan = Bulk.plan(:stack, [p1.uuid, p3.uuid], ctx.scope, %{"title" => ""})
      assert %{failed: []} = Bulk.run(plan)
      assert Stacks.get(reload(p3).stack_uuid).title == "Lease"
    end

    test "add to a stack: one photo or more, the stack chosen by its id", ctx do
      [p1, p2, p3] = pages(ctx, 3)
      {:ok, stack} = Stacks.create([p1.uuid, p3.uuid], ctx.scope, %{title: "Lease"})
      single = photo(ctx, %{original_file_name: "late.jpg", taken_at: ~U[2018-07-15 10:00:00Z]})

      assert Bulk.whole_stacks([p1.uuid], :stack_add, ctx.scope) == [p1.uuid]

      # No stack chosen, or one that is not there: nothing can go.
      assert [%{reason: :no_stack}] = Bulk.plan(:stack_add, [p2.uuid], ctx.scope).refused

      assert [%{reason: :no_stack}] =
               Bulk.plan(:stack_add, [p2.uuid], ctx.scope, %{"stack" => Ecto.UUID.generate()}).refused

      # Someone who may not change the files.
      refused =
        Bulk.plan(:stack_add, [p2.uuid], scope_for(ctx.stranger), %{"stack" => stack.uuid})

      assert refused.files == []

      # The stack's own cover chosen with them is already there; the rest go in by date.
      plan =
        Bulk.plan(:stack_add, [p1.uuid, single.uuid, p2.uuid], ctx.scope, %{"stack" => stack.uuid})

      assert [%{reason: :in_stack}] = plan.refused
      assert %{done: done, failed: []} = Bulk.run(plan)
      assert Enum.sort(done) == Enum.sort([p2.uuid, single.uuid])

      assert Enum.map(Stacks.files(stack.uuid), & &1.uuid) ==
               [p1.uuid, p2.uuid, p3.uuid, single.uuid]

      # In another library: refused before anything is tried.
      far = photo(%{ctx | library: library_fixture(ctx.owner)})

      assert [%{reason: :mixed_libraries}] =
               Bulk.plan(:stack_add, [far.uuid], ctx.scope, %{"stack" => stack.uuid}).refused
    end

    test "a stack of one is refused, and says why", ctx do
      [p1] = pages(ctx, 1)
      plan = Bulk.plan(:stack, [p1.uuid], ctx.scope)
      assert %{done: [], failed: [%{reason: :too_few}]} = Bulk.run(plan)
      assert Bulk.reason_text(:too_few) =~ "two"
    end

    test "copies of a stack are a stack in the target, in the same order, with its text", ctx do
      [p1, p2, p3] = pages(ctx, 3)
      {:ok, _} = Stacks.create([p1.uuid, p2.uuid, p3.uuid], ctx.scope, %{title: "Lease"})
      {:ok, _} = Stacks.make_cover(p3.uuid, ctx.scope)
      other = library_fixture(ctx.owner)

      copies =
        Map.new([p1, p2, p3], fn file ->
          {file.uuid, file_fixture(ctx.owner, %{library_uuid: other.uuid}).uuid}
        end)

      files = Enum.map([p1, p2, p3], &reload/1)
      Bulk.restack(%{auth: ctx.scope}, files, copies)

      stack = Stacks.get(TestRepo.get!(StorageFile, copies[p1.uuid]).stack_uuid)
      assert stack.title == "Lease"
      assert stack.library_uuid == other.uuid

      assert Enum.map(Stacks.files(stack.uuid), & &1.uuid) ==
               [copies[p3.uuid], copies[p1.uuid], copies[p2.uuid]]

      # One copy of a stack is no stack.
      [q1, q2] = pages(ctx, 2)
      {:ok, _} = Stacks.create([q1.uuid, q2.uuid], ctx.scope)
      lone = file_fixture(ctx.owner, %{library_uuid: other.uuid})
      Bulk.restack(%{auth: ctx.scope}, [reload(q1), reload(q2)], %{q1.uuid => lone.uuid})
      assert is_nil(TestRepo.get!(StorageFile, lone.uuid).stack_uuid)
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
    {:ok, _} = Storage.trash_file(a)
    refute one == Bulk.fingerprint(Bulk.plan(:trash, [a.uuid, b.uuid], ctx.scope))
  end

  describe "dates and places" do
    test "dated together: the earliest gets the date, the others keep their distance", ctx do
      a = photo(ctx, %{taken_at: ~U[2018-07-14 12:00:00Z], taken_on: ~D[2018-07-14]})
      b = photo(ctx, %{taken_at: ~U[2018-07-14 12:30:00Z], taken_on: ~D[2018-07-14]})

      plan =
        Bulk.plan(:date, [b.uuid, a.uuid], ctx.scope, %{"date" => "1985-03-12", "time" => "09:00"})

      assert plan.date == {:set, ~N[1985-03-12 09:00:00]}
      assert %{done: done, failed: []} = Bulk.run(plan)
      assert length(done) == 2

      assert reload(a).taken_at == ~U[1985-03-12 09:00:00Z]
      assert reload(b).taken_at == ~U[1985-03-12 09:30:00Z]
      assert reload(b).taken_at_source == "manual"

      plan = Bulk.plan(:date, [a.uuid, b.uuid], ctx.scope, %{"mode" => "reset"})
      assert plan.date == :reset
      assert %{done: [_, _]} = Bulk.run(plan)
      refute reload(a).taken_at_source == "manual"
    end

    test "no date is no plan to run, and a viewer may not date", ctx do
      a = photo(ctx)
      assert Bulk.plan(:date, [a.uuid], ctx.scope, %{"date" => "soon"}).date == nil

      member_fixture(ctx.library, ctx.stranger, "viewer")

      assert [%{reason: :not_allowed}] =
               Bulk.plan(:date, [a.uuid], scope_for(ctx.stranger), %{"date" => "1999-01-01"}).refused
    end

    test "one place for them all, by hand, then none", ctx do
      a = photo(ctx)
      b = photo(ctx)

      plan =
        Bulk.plan(:place, [a.uuid, b.uuid], ctx.scope, %{
          "lat" => "58.38",
          "lon" => "26.72",
          "name" => "Tartu"
        })

      assert plan.place == {:set, {58.38, 26.72}, "Tartu"}
      assert %{done: [_, _]} = Bulk.run(plan)
      assert {reload(a).latitude, reload(b).longitude} == {58.38, 26.72}

      assert Bulk.plan(:place, [a.uuid], ctx.scope, %{"lat" => "200", "lon" => "0"}).place == nil

      plan = Bulk.plan(:place, [a.uuid, b.uuid], ctx.scope, %{"mode" => "clear"})
      assert %{done: [_, _]} = Bulk.run(plan)
      assert reload(a).latitude == nil
      assert reload(a).metadata["location_source"] == "manual"
    end
  end
end
