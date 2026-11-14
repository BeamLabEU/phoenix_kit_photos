defmodule PhoenixKitPhotos.ChaptersTest do
  @moduledoc """
  A library's chapters: who may make and change them, the rules of sub-chapters, and what
  the timeline does with them (banners in the index, a cover this reader may see, the aspect
  ratios grouped by the same sections, a stranger seeing nothing).
  """
  use PhoenixKitPhotos.DataCase, async: false

  alias PhoenixKitPhotos.Chapter
  alias PhoenixKitPhotos.Chapters
  alias PhoenixKitPhotos.Components.ChapterEdit

  @viewer :viewer
  @contributor :contributor

  setup do
    _ = {@viewer, @contributor}
    _ = start_supervised(PhoenixKit.PubSub.Manager)
    owner = user_fixture("chapters-owner-#{System.unique_integer([:positive])}@example.com")
    stranger = user_fixture("chapters-stranger-#{System.unique_integer([:positive])}@example.com")
    library = library_fixture(owner)

    %{
      owner: owner,
      stranger: stranger,
      library: library,
      scope: scope_for(owner),
      lib: {:library, library.uuid}
    }
  end

  defp photo(ctx, %Date{} = day, hh \\ 12) do
    {:ok, at} = DateTime.new(day, Time.new!(hh, 0, 0))
    file_fixture(ctx.owner, %{library_uuid: ctx.library.uuid, taken_on: day, taken_at: at})
  end

  defp chapter!(ctx, attrs) do
    {:ok, chapter} = Chapters.create(ctx.scope, ctx.library.uuid, attrs)
    chapter
  end

  describe "who" do
    test "the owner makes, changes and deletes; others may not", ctx do
      Chapters.subscribe()
      library_uuid = ctx.library.uuid

      chapter = chapter!(ctx, %{"title" => "  Trip   to France ", "starts_on" => "2026-07-12"})
      assert chapter.title == "Trip to France"
      assert chapter.created_by_uuid == ctx.owner.uuid
      assert_receive {:phoenix_kit_photos_chapters_changed, ^library_uuid}

      stranger = scope_for(ctx.stranger)

      assert Chapters.create(stranger, ctx.library.uuid, %{
               "title" => "x",
               "starts_on" => "2026-07-01"
             }) ==
               {:error, :forbidden}

      assert Chapters.update(stranger, chapter, %{"title" => "Mine"}) == {:error, :forbidden}
      assert Chapters.delete(stranger, chapter) == {:error, :forbidden}

      member_fixture(ctx.library, ctx.stranger, "viewer")

      assert Chapters.update(scope_for(ctx.stranger), chapter, %{"title" => "Mine"}) ==
               {:error, :forbidden}

      assert {:ok, %Chapter{title: "Trip"}} =
               Chapters.update(ctx.scope, chapter, %{"title" => "Trip"})

      assert {:ok, _} = Chapters.delete(ctx.scope, chapter)
      assert Chapters.list(ctx.library.uuid) == []
    end

    test "what is checked: a title, a start, an end after it, a known colour", ctx do
      assert {:error, %Ecto.Changeset{} = cs} =
               Chapters.create(ctx.scope, ctx.library.uuid, %{"title" => ""})

      assert cs.errors[:title] && cs.errors[:starts_on]

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Chapters.create(ctx.scope, ctx.library.uuid, %{
                 "title" => "x",
                 "starts_on" => "2026-07-12",
                 "ends_on" => "2026-07-01",
                 "color" => "red; background: url(x)"
               })

      assert errors[:ends_on] && errors[:color]
    end

    test "a cover from another library is refused", ctx do
      elsewhere = file_fixture(ctx.owner, %{library_uuid: library_fixture(ctx.owner).uuid})

      assert Chapters.create(ctx.scope, ctx.library.uuid, %{
               "title" => "x",
               "starts_on" => "2026-07-12",
               "cover_file_uuid" => elsewhere.uuid
             }) == {:error, :not_found}
    end
  end

  describe "sub-chapters" do
    setup ctx do
      trip =
        chapter!(ctx, %{
          "title" => "France",
          "starts_on" => "2026-07-12",
          "ends_on" => "2026-07-20"
        })

      %{trip: trip}
    end

    test "inside its chapter's days, one level only", ctx do
      paris =
        chapter!(ctx, %{
          "title" => "Paris",
          "starts_on" => "2026-07-12",
          "ends_on" => "2026-07-15",
          "parent_uuid" => ctx.trip.uuid
        })

      assert paris.parent_uuid == ctx.trip.uuid

      assert Chapters.create(ctx.scope, ctx.library.uuid, %{
               "title" => "Too late",
               "starts_on" => "2026-07-19",
               "ends_on" => "2026-07-22",
               "parent_uuid" => ctx.trip.uuid
             }) == {:error, :outside_parent}

      # A sub-chapter holds none of its own…
      assert Chapters.create(ctx.scope, ctx.library.uuid, %{
               "title" => "Louvre",
               "starts_on" => "2026-07-13",
               "parent_uuid" => paris.uuid
             }) == {:error, :bad_parent}

      # …and a chapter with sub-chapters is no one's sub-chapter.
      other =
        chapter!(ctx, %{
          "title" => "Summer",
          "starts_on" => "2026-06-01",
          "ends_on" => "2026-08-31"
        })

      assert Chapters.update(ctx.scope, ctx.trip, %{"parent_uuid" => other.uuid}) ==
               {:error, :has_sub_chapters}

      # Its chapter's days cannot leave it out.
      assert Chapters.update(ctx.scope, ctx.trip, %{"starts_on" => "2026-07-14"}) ==
               {:error, :sub_chapter_outside}

      # Another library's chapter is no parent.
      other_lib = library_fixture(ctx.owner)

      {:ok, foreign} =
        Chapters.create(ctx.scope, other_lib.uuid, %{"title" => "x", "starts_on" => "2026-07-01"})

      assert Chapters.create(ctx.scope, ctx.library.uuid, %{
               "title" => "y",
               "starts_on" => "2026-07-13",
               "parent_uuid" => foreign.uuid
             }) == {:error, :bad_parent}
    end

    test "deleting a chapter deletes its sub-chapters", ctx do
      chapter!(ctx, %{
        "title" => "Paris",
        "starts_on" => "2026-07-13",
        "parent_uuid" => ctx.trip.uuid
      })

      assert Chapters.sub_chapter_count(ctx.trip) == 1
      {:ok, _} = Chapters.delete(ctx.scope, ctx.trip)
      assert Chapters.list(ctx.library.uuid) == []
    end
  end

  describe "the timeline" do
    test "a chapter is a banner section, with a cover this reader may see", ctx do
      photo(ctx, ~D[2026-07-02])
      first = photo(ctx, ~D[2026-07-12], 9)
      photo(ctx, ~D[2026-07-12], 15)
      photo(ctx, ~D[2026-07-25])

      chapter!(ctx, %{
        "title" => "France",
        "emoji" => "✈️",
        "starts_on" => "2026-07-12",
        "ends_on" => "2026-07-20"
      })

      {:ok, index} = Timeline.index(ctx.lib, ctx.scope)
      assert index.total == 4

      assert Enum.map(index.sections, & &1.id)
             |> Enum.drop(1)
             |> hd()
             |> String.starts_with?("c:")

      [before, banner, back] = index.sections
      assert before.id == "2026-07" and before.span == [1, 11]
      assert banner.chapter.title == "France"
      assert banner.chapter.count == 2
      assert is_binary(banner.chapter.cover) or banner.chapter.cover == nil
      refute Map.has_key?(banner.chapter, :cover_file)
      assert back.id == "2026-07~2" and back.after.title == "France"

      # The ratios come grouped by the same sections.
      {:ok, aspects} = Timeline.aspects(ctx.lib, ctx.scope)

      assert Map.new(aspects, fn {id, bytes} -> {id, byte_size(bytes)} end) ==
               %{"2026-07" => 1, banner.id => 2, "2026-07~2" => 1}

      # The windows are still days: the banner's first day starts with its first photo.
      {:ok, %{items: [item | _]}} = Timeline.window(ctx.lib, "2026-07-12", ctx.scope)
      assert item.id == first.uuid
    end

    test "a stranger sees no banner, nor anything", ctx do
      photo(ctx, ~D[2026-07-12])
      chapter!(ctx, %{"title" => "France", "starts_on" => "2026-07-12"})
      assert {:error, _} = Timeline.index(ctx.lib, scope_for(ctx.stranger))
    end
  end

  describe "the dialog" do
    test "made from chosen photos: their days, the first as cover, the chapter they are in",
         ctx do
      trip =
        chapter!(ctx, %{
          "title" => "France",
          "starts_on" => "2026-07-10",
          "ends_on" => "2026-07-20"
        })

      a = photo(ctx, ~D[2026-07-12], 9)
      b = photo(ctx, ~D[2026-07-14])

      edit = ChapterEdit.new(ctx.scope, ctx.library.uuid, [b.uuid, a.uuid])
      assert edit.params["starts_on"] == "2026-07-12"
      assert edit.params["ends_on"] == "2026-07-14"
      assert edit.params["cover_file_uuid"] == a.uuid
      assert edit.params["parent_uuid"] == trip.uuid

      edit = ChapterEdit.change(edit, %{"title" => "Paris", "bogus" => "x"})
      refute Map.has_key?(edit.params, "bogus")
      assert {:ok, paris} = ChapterEdit.apply("save", edit, ctx.scope)
      assert paris.parent_uuid == trip.uuid and paris.cover_file_uuid == a.uuid

      assert ChapterEdit.new(scope_for(ctx.stranger), ctx.library.uuid, [a.uuid]) == nil
      assert ChapterEdit.edit(scope_for(ctx.stranger), paris.uuid, ctx.library.uuid) == nil
      assert %{chapter: %Chapter{}} = ChapterEdit.edit(ctx.scope, paris.uuid, ctx.library.uuid)
    end
  end
end
