defmodule PhoenixKitPhotos.PhotoTimelineStacksTest do
  @moduledoc """
  The timeline component's side of stacks in the swipe viewer: a stack's pages on request, the
  page an address names, and the viewer's Edit stack (title, date, cover, taking a photo out,
  taking the stack apart).
  """
  use PhoenixKitPhotos.DataCase, async: false
  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Stacks

  @endpoint PhoenixKitPhotos.TestEndpoint

  setup do
    start_supervised!({Phoenix.PubSub, name: PhoenixKitPhotos.TestPubSub})
    start_supervised!(PhoenixKitPhotos.TestEndpoint)
    start_supervised!(PhoenixKit.PubSub.Manager)
    user = user_fixture("stack-live-#{System.unique_integer([:positive])}@example.com")

    # Two pages in the user's own uploads to Media, and a photo after them.
    p1 =
      file_fixture(user, %{original_file_name: "page 1.jpg", taken_at: ~U[2018-07-14 10:00:00Z]})

    p2 =
      file_fixture(user, %{original_file_name: "page 2.jpg", taken_at: ~U[2018-07-14 10:01:00Z]})

    after_ =
      file_fixture(user, %{original_file_name: "after.jpg", taken_at: ~U[2018-07-14 11:00:00Z]})

    {:ok, stack} = Stacks.create([p1.uuid, p2.uuid], scope_for(user), %{title: "Lease"})

    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), PhoenixKitPhotos.TestLive,
        session: %{"scope" => scope_for(user), "library" => {:library, media_uuid()}}
      )

    assert_push_event(view, "timeline:test-timeline:index", %{hello: false})
    view |> element("#test-timeline-viewport") |> render_hook("timeline:ready", %{})

    assert_push_event(view, "timeline:test-timeline:index", %{
      hello: true,
      revision: revision,
      total: 2
    })

    %{view: view, user: user, stack: stack, p1: p1, p2: p2, after: after_, revision: revision}
  end

  defp reload(file), do: TestRepo.get!(StorageFile, file.uuid)

  defp edit(ctx, file) do
    ctx.view
    |> element("#test-timeline-viewport")
    |> render_hook("timeline:stack_edit", %{"stack" => ctx.stack.uuid, "file" => file.uuid})
  end

  test "the viewer gets a stack's pages, and an address of a page says which", ctx do
    ctx.view
    |> element("#test-timeline-viewport")
    |> render_hook("timeline:stack", %{
      "stack" => ctx.stack.uuid,
      "cover" => ctx.p1.uuid,
      "want" => 1200,
      "revision" => ctx.revision
    })

    stack_id = ctx.stack.uuid
    cover = ctx.p1.uuid

    assert_push_event(ctx.view, "timeline:test-timeline:stack", %{
      stack: ^stack_id,
      cover: ^cover,
      pages: pages
    })

    assert Enum.map(pages, & &1.id) == [ctx.p1.uuid, ctx.p2.uuid]

    # Asked in an old revision: no answer.
    ctx.view
    |> element("#test-timeline-viewport")
    |> render_hook("timeline:stack", %{
      "stack" => ctx.stack.uuid,
      "cover" => ctx.p1.uuid,
      "want" => 1200,
      "revision" => ctx.revision - 1
    })

    refute_push_event(ctx.view, "timeline:test-timeline:stack", %{}, 100)

    p2 = ctx.p2.uuid
    send(ctx.view.pid, {:view, p2})
    assert_push_event(ctx.view, "timeline:test-timeline:view", %{id: ^p2, global: 0, page: 1})

    after_id = ctx.after.uuid
    send(ctx.view.pid, {:view, after_id})

    assert_push_event(ctx.view, "timeline:test-timeline:view", %{
      id: ^after_id,
      global: 1,
      page: 0
    })
  end

  test "Edit stack: a title, and a date that moves every page together", ctx do
    html = edit(ctx, ctx.p2)
    assert html =~ "Stack of 2 photos"
    assert html =~ ~s(value="Lease")
    assert html =~ ~s(value="2018-07-14")
    assert html =~ ~s(value="10:00")
    assert html =~ "Make this the cover"

    ctx.view
    |> element("#test-timeline-stack-edit form")
    |> render_submit(%{
      "title" => "Lease 1985",
      "description" => "Signed in March.",
      "date" => "1985-03-12",
      "time" => ""
    })

    stack = Stacks.get(ctx.stack.uuid)
    assert {stack.title, stack.description} == {"Lease 1985", "Signed in March."}
    assert reload(ctx.p1).taken_at == ~U[1985-03-12 10:00:00Z]
    assert reload(ctx.p2).taken_at == ~U[1985-03-12 10:01:00Z]
    assert reload(ctx.p2).taken_at_source == "manual"
    refute has_element?(ctx.view, "#test-timeline-stack-edit")

    # The viewer is told where the photo on screen is now: the stack went before "after".
    p2 = ctx.p2.uuid
    assert_push_event(ctx.view, "timeline:test-timeline:view", %{id: ^p2, global: 0, page: 1})

    # The way back is offered now that the dates are a person's.
    assert edit(ctx, ctx.p1) =~ "Use the photos&#39; own dates"
    ctx.view |> element("button", "Use the photos' own dates") |> render_click()
    assert reload(ctx.p1).taken_at_source != "manual"
  end

  test "an impossible date is said, and nothing changes", ctx do
    edit(ctx, ctx.p1)

    html =
      ctx.view
      |> element("#test-timeline-stack-edit form")
      |> render_submit(%{
        "title" => "Lease",
        "description" => "",
        "date" => "1700-01-01",
        "time" => ""
      })

    assert html =~ "before 1826 or in the future"
    assert reload(ctx.p1).taken_at == ctx.p1.taken_at
  end

  test "the cover, taking a page out, and taking the stack apart", ctx do
    edit(ctx, ctx.p2)
    ctx.view |> element("button", "Make this the cover") |> render_click()
    assert Enum.map(Stacks.files(ctx.stack.uuid), & &1.uuid) == [ctx.p2.uuid, ctx.p1.uuid]

    edit(ctx, ctx.p1)
    ctx.view |> element("button", "Take this photo out") |> render_click()
    # A stack of one is no stack.
    assert is_nil(reload(ctx.p2).stack_uuid)
    assert Stacks.get(ctx.stack.uuid) == nil

    # Nothing to edit any more.
    edit(ctx, ctx.p1)
    refute has_element?(ctx.view, "#test-timeline-stack-edit")
  end

  test "someone who may not change it gets no dialog", ctx do
    stranger = user_fixture("stack-stranger-#{System.unique_integer([:positive])}@example.com")

    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), PhoenixKitPhotos.TestLive,
        session: %{"scope" => scope_for(stranger), "library" => {:library, media_uuid()}}
      )

    view
    |> element("#test-timeline-viewport")
    |> render_hook("timeline:stack_edit", %{"stack" => ctx.stack.uuid, "file" => ctx.p1.uuid})

    refute has_element?(view, "#test-timeline-stack-edit")
  end

  # The selection bar, on a library of the user's own that they may add to.
  defp bar(ctx) do
    library = library_fixture(ctx.user)

    [a, b, c] =
      for {name, at} <- [
            {"a.jpg", ~U[2019-01-01 10:00:00Z]},
            {"b.jpg", ~U[2019-01-01 10:01:00Z]},
            {"c.jpg", ~U[2019-01-01 12:00:00Z]}
          ],
          do:
            file_fixture(ctx.user, %{
              original_file_name: name,
              taken_at: at,
              library_uuid: library.uuid
            })

    {:ok, stack} = Stacks.create([a.uuid, b.uuid], scope_for(ctx.user), %{title: "Receipts"})

    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), PhoenixKitPhotos.TestLive,
        session: %{
          "scope" => scope_for(ctx.user),
          "library" => {:library, library.uuid},
          "selectable" => true
        }
      )

    %{view: view, a: a, b: b, c: c, stack: stack}
  end

  test "the bar's Stack is a menu: New stack, and Add to a stack", ctx do
    %{view: view} = bar(ctx)
    assert has_element?(view, "[data-bulk-menu] [data-bulk=stack][data-min='2']")
    assert has_element?(view, "[data-bulk-menu] [data-bulk=stack_add][data-min='1']")
    refute has_element?(view, "[data-selection-bar] > div > button[data-bulk=stack]")
  end

  test "Add to a stack from the bar: a stack among those chosen is the one meant", ctx do
    %{view: view, a: a, c: c, stack: stack} = bar(ctx)

    html =
      view
      |> element("#test-timeline-viewport")
      |> render_hook("timeline:bulk", %{"action" => "stack_add", "ids" => [a.uuid, c.uuid]})

    assert html =~ "Add 1 item to a stack"

    assert has_element?(
             view,
             "#test-timeline-bulk input[name=stack][value='#{stack.uuid}'][checked]"
           )

    # With no stack among them, none is chosen yet: what was chosen is counted, Add waits.
    html =
      view
      |> element("#test-timeline-viewport")
      |> render_hook("timeline:bulk", %{"action" => "stack_add", "ids" => [c.uuid]})

    assert html =~ "Add 1 item to a stack"
    refute html =~ "no stack chosen"
    assert has_element?(view, "#test-timeline-bulk button[type=submit][disabled]")

    view |> element("#test-timeline-bulk") |> render_change(%{"stack" => stack.uuid, "q" => ""})
    refute has_element?(view, "#test-timeline-bulk button[type=submit][disabled]")

    # Back to what was chosen first.
    view
    |> element("#test-timeline-viewport")
    |> render_hook("timeline:bulk", %{"action" => "stack_add", "ids" => [a.uuid, c.uuid]})

    assert html =~ "Receipts"
    # The stack's own cover chosen with it needs no word.
    refute html =~ "already in that stack"

    view |> element("#test-timeline-bulk") |> render_submit(%{"stack" => stack.uuid, "q" => ""})

    assert eventually(fn -> length(Stacks.files(stack.uuid)) == 3 end)

    assert Enum.map(Stacks.files(stack.uuid), & &1.original_file_name) == [
             "a.jpg",
             "b.jpg",
             "c.jpg"
           ]

    assert Stacks.get(stack.uuid).title == "Receipts"
  end

  test "Add to stack in the viewer: one photo into a stack picked by title", ctx do
    lone = ctx.after.uuid

    html =
      ctx.view
      |> element("#test-timeline-viewport")
      |> render_hook("timeline:pick_stack", %{"file" => lone})

    assert html =~ "Add to a stack"

    assert has_element?(
             ctx.view,
             "#test-timeline-stack-pick input[name=stack][value='#{ctx.stack.uuid}']"
           )

    # Found by its title, or not.
    html =
      ctx.view |> element("#test-timeline-stack-pick form") |> render_change(%{"q" => "nothing"})

    assert html =~ "No stack has that in its title."
    html = ctx.view |> element("#test-timeline-stack-pick form") |> render_change(%{"q" => "lea"})
    assert html =~ "Lease"

    ctx.view
    |> element("#test-timeline-stack-pick form")
    |> render_submit(%{"stack" => ctx.stack.uuid, "q" => "lea"})

    refute has_element?(ctx.view, "#test-timeline-stack-pick")
    assert Enum.map(Stacks.files(ctx.stack.uuid), & &1.uuid) == [ctx.p1.uuid, ctx.p2.uuid, lone]

    # The viewer follows the photo: the stack's place, its third page.
    assert_push_event(ctx.view, "timeline:test-timeline:view", %{id: ^lone, global: 0, page: 2})
  end

  test "no Add to stack dialog for someone who may not change the library", ctx do
    stranger = user_fixture("pick-stranger-#{System.unique_integer([:positive])}@example.com")

    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), PhoenixKitPhotos.TestLive,
        session: %{"scope" => scope_for(stranger), "library" => {:library, media_uuid()}}
      )

    view
    |> element("#test-timeline-viewport")
    |> render_hook("timeline:pick_stack", %{"file" => ctx.after.uuid})

    refute has_element?(view, "#test-timeline-stack-pick")
  end

  defp eventually(check, tries \\ 40) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(check, tries - 1)
    end
  end
end
