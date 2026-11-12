defmodule PhoenixKitPhotos.TimelineStacksTest do
  @moduledoc """
  A stack takes one place in the timeline: the index, the windows, the slides, the
  positions and the ranges count its cover only, the first of its files the reader may
  see. A trashed cover hands over; a reader who sees only some of its files gets a stack
  of those; the viewer gets every page (`stack_slides/4`) and the page an address names.
  """
  use PhoenixKitPhotos.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Stacks

  import Ecto.Query, only: [from: 2]

  setup do
    start_supervised!(PhoenixKit.PubSub.Manager)

    owner = user_fixture("stacks-owner-#{System.unique_integer([:positive])}@example.com")
    library = library_fixture(owner)
    %{owner: owner, scope: scope_for(owner), library: library, lib: {:library, library.uuid}}
  end

  # A photo of `library` on 14 July 2018 at `hh:mm`.
  defp photo(ctx, name, hh_mm, attrs \\ %{}) do
    {:ok, at, 0} = DateTime.from_iso8601("2018-07-14T#{hh_mm}:00Z")

    file_fixture(
      ctx.owner,
      Map.merge(
        %{original_file_name: name, library_uuid: ctx.library.uuid, taken_at: at},
        attrs
      )
    )
  end

  defp window_names(ctx, scope \\ nil) do
    {:ok, %{items: items}} = Timeline.window(ctx.lib, "2018-07-14", scope || ctx.scope)
    Enum.map(items, & &1.name)
  end

  defp stack!(ctx, files, attrs \\ %{}) do
    {:ok, stack} = Stacks.create(Enum.map(files, & &1.uuid), ctx.scope, attrs)
    stack
  end

  test "a stack is one place: its cover, with the count and title", ctx do
    before = photo(ctx, "before.jpg", "09:00")
    p1 = photo(ctx, "page 1.jpg", "10:00")
    p2 = photo(ctx, "page 2.jpg", "10:01")
    p3 = photo(ctx, "page 3.jpg", "10:02")
    after_ = photo(ctx, "after.jpg", "11:00")
    stack = stack!(ctx, [p3, p1, p2], %{title: "Lease"})

    assert window_names(ctx) == ["before.jpg", "page 1.jpg", "after.jpg"]

    {:ok, %{items: items}} = Timeline.window(ctx.lib, "2018-07-14", ctx.scope)
    assert Enum.map(items, & &1.stack) == [nil, %{id: stack.uuid, count: 3, title: "Lease"}, nil]

    {:ok, index} = Timeline.index(ctx.lib, ctx.scope)
    assert index.total == 3
    assert [%{count: 3, days_list: [%{id: "2018-07-14", count: 3}]}] = index.sections

    {:ok, aspects} = Timeline.aspects(ctx.lib, ctx.scope)
    assert byte_size(aspects["2018-07"]) == 3

    {:ok, slides} = Timeline.slides(ctx.lib, "2018-07-14", 0, 10, 1200, ctx.scope)
    assert Enum.map(slides, & &1.id) == [before.uuid, p1.uuid, after_.uuid]
    assert Enum.at(slides, 1).stack.count == 3

    {:ok, ids, false} = Timeline.ids_between(ctx.lib, ctx.scope, limit: 100)
    assert ids == [before.uuid, p1.uuid, after_.uuid]
  end

  test "an address of any page opens at the stack, on that page", ctx do
    photo(ctx, "before.jpg", "09:00")
    p1 = photo(ctx, "page 1.jpg", "10:00")
    p2 = photo(ctx, "page 2.jpg", "10:01")
    p3 = photo(ctx, "page 3.jpg", "10:02")
    after_ = photo(ctx, "after.jpg", "11:00")
    stack!(ctx, [p1, p2, p3])

    for {file, page} <- [{p1, 0}, {p2, 1}, {p3, 2}] do
      assert Timeline.position(ctx.lib, file.uuid, ctx.scope) == {:ok, 1}
      assert Timeline.stack_page(ctx.lib, file.uuid, ctx.scope) == {:ok, page}
    end

    assert Timeline.position(ctx.lib, after_.uuid, ctx.scope) == {:ok, 2}
    assert Timeline.stack_page(ctx.lib, after_.uuid, ctx.scope) == {:ok, 0}

    # The viewer's canvas still opens any page by itself.
    assert {:ok, %{file_uuid: uuid}} = Timeline.viewer_file(ctx.lib, p3.uuid, ctx.scope)
    assert uuid == p3.uuid
  end

  test "the stack's pages for the viewer, in order, with a small picture each", ctx do
    p1 = photo(ctx, "page 1.jpg", "10:00")
    p2 = photo(ctx, "page 2.jpg", "10:01")
    stack = stack!(ctx, [p2, p1], %{title: "Two"})

    assert {:ok, %{stack: summary, slides: slides}} =
             Timeline.stack_slides(ctx.lib, stack.uuid, 1200, ctx.scope)

    assert summary == %{id: stack.uuid, count: 2, title: "Two"}
    assert Enum.map(slides, & &1.id) == [p1.uuid, p2.uuid]
    assert Enum.all?(slides, &Map.has_key?(&1, :thumb))

    # Not this library's, not a stack, not readable.
    other = library_fixture(ctx.owner)

    assert Timeline.stack_slides({:library, other.uuid}, stack.uuid, 1200, ctx.scope) ==
             {:error, :not_found}

    assert Timeline.stack_slides(ctx.lib, Ecto.UUID.generate(), 1200, ctx.scope) ==
             {:error, :not_found}

    stranger = scope_for(user_fixture("stranger-#{System.unique_integer([:positive])}@x.com"))
    assert {:error, _} = Timeline.stack_slides(ctx.lib, stack.uuid, 1200, stranger)
  end

  test "a trashed cover hands over to the next page, and is back when restored", ctx do
    p1 = photo(ctx, "page 1.jpg", "10:00")
    p2 = photo(ctx, "page 2.jpg", "10:01")
    p3 = photo(ctx, "page 3.jpg", "10:02")
    stack!(ctx, [p1, p2, p3])

    {:ok, _} = Storage.trash_file(p1)
    assert window_names(ctx) == ["page 2.jpg"]
    {:ok, %{items: [item]}} = Timeline.window(ctx.lib, "2018-07-14", ctx.scope)
    assert item.stack.count == 2

    {:ok, _} = Storage.trash_file(Storage.get_file(p2.uuid))
    # One page left: a single photo to the reader.
    {:ok, %{items: [item]}} = Timeline.window(ctx.lib, "2018-07-14", ctx.scope)
    assert item.name == "page 3.jpg"
    assert item.stack == nil

    {:ok, _} = Storage.restore_file(p1.uuid)
    assert window_names(ctx) == ["page 1.jpg"]
  end

  test "someone who reads only their own uploads gets a stack of those", ctx do
    # In Media a user reads only their own uploads (`restrict`); the cover query follows
    # the same rule, so their cover is the first page that is theirs.
    admin = scope_for(ctx.owner, ["Owner"])
    them = user_fixture("them-#{System.unique_integer([:positive])}@example.com")
    media = {:library, media_uuid()}

    on = fn user, name, at ->
      file_fixture(user, %{original_file_name: name, taken_at: at, taken_on: ~D[2018-07-14]})
    end

    first = on.(ctx.owner, "owner page.jpg", ~U[2018-07-14 10:00:00Z])
    second = on.(them, "their page 1.jpg", ~U[2018-07-14 10:01:00Z])
    third = on.(them, "their page 2.jpg", ~U[2018-07-14 10:02:00Z])
    {:ok, _} = Stacks.create([first.uuid, second.uuid, third.uuid], admin)

    {:ok, %{items: [item]}} = Timeline.window(media, "2018-07-14", admin)
    assert {item.name, item.stack.count} == {"owner page.jpg", 3}

    {:ok, %{items: [item]}} = Timeline.window(media, "2018-07-14", scope_for(them))
    assert {item.name, item.stack.count} == {"their page 1.jpg", 2}
    assert Timeline.stack_page(media, third.uuid, scope_for(them)) == {:ok, 1}
  end

  test "taken apart, its files are single photos where they were", ctx do
    p1 = photo(ctx, "page 1.jpg", "10:00")
    p2 = photo(ctx, "page 2.jpg", "10:01")
    stack = stack!(ctx, [p1, p2])

    {:ok, _} = Stacks.unstack(stack.uuid, ctx.scope)
    assert window_names(ctx) == ["page 1.jpg", "page 2.jpg"]
  end

  test "the stacks to add to: the latest changed first, found by title, one put first", ctx do
    [a1, a2, b1, b2, c1] =
      for {name, at} <- [
            {"a1.jpg", "08:00"},
            {"a2.jpg", "08:01"},
            {"b1.jpg", "09:00"},
            {"b2.jpg", "09:01"},
            {"c1.jpg", "10:00"}
          ],
          do: photo(ctx, name, at)

    lease = stack!(ctx, [a1, a2], %{title: "Lease 100%"})
    receipts = stack!(ctx, [b1, b2])
    # The lease was changed last (times to the second, so set apart here).
    for {stack, at} <- [{receipts, ~N[2026-01-01 10:00:00]}, {lease, ~N[2026-01-02 10:00:00]}] do
      TestRepo.update_all(
        from(s in PhoenixKit.Modules.Storage.FileStack, where: s.uuid == ^stack.uuid),
        set: [updated_at: at]
      )
    end

    _single = c1

    {:ok, stacks} = Timeline.stacks(ctx.lib, ctx.scope)
    assert Enum.map(stacks, & &1.id) == [lease.uuid, receipts.uuid]
    assert [%{title: "Lease 100%", count: 2, cover: cover, taken_at: %DateTime{}} | _] = stacks
    assert cover == a1.uuid

    # A title search, with % taken as itself.
    assert {:ok, [%{id: id}]} = Timeline.stacks(ctx.lib, ctx.scope, query: "100%")
    assert id == lease.uuid
    assert {:ok, []} = Timeline.stacks(ctx.lib, ctx.scope, query: "0%x")

    assert {:ok, [%{id: first} | _]} = Timeline.stacks(ctx.lib, ctx.scope, first: receipts.uuid)
    assert first == receipts.uuid

    stranger = user_fixture("stacks-stranger-#{System.unique_integer([:positive])}@example.com")
    assert {:error, _} = Timeline.stacks(ctx.lib, scope_for(stranger))
  end
end
