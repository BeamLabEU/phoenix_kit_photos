defmodule PhoenixKitPhotos.TimelineTest do
  use ExUnit.Case, async: true

  alias PhoenixKitPhotos.Timeline

  describe "base_filters/0" do
    test "excludes the rows that would pollute a naive query" do
      filters = Timeline.base_filters()

      # Tessera tile pyramids and edit backups.
      assert filters[:system_managed] == false
      assert filters[:parent_file_uuid] == nil
      # Trash.
      assert filters[:trashed_at] == nil
      # Rows with no variants render as permanently grey tiles.
      assert filters[:status] == "active"
      # Zero dimensions blow up the aspect ratio and the layout.
      assert filters[:dimensions] == :positive
      assert filters[:file_type] == ["image", "video"]
    end

    test "does not filter edit_state" do
      # A pending or failed edit occupies the same uuid and belongs in the
      # grid; FileController already serves a placeholder for it.
      refute Keyword.has_key?(Timeline.base_filters(), :edit_state)
    end
  end

  describe "window_limit/0" do
    test "caps a window so a fat day cannot flood the socket" do
      assert Timeline.window_limit() == 500
    end
  end

  describe "capture date is not available yet" do
    test "index/1 says so rather than bucketing by upload date" do
      assert Timeline.index({:user, "01234567-89ab-7def-8123-456789abcdef"}) ==
               {:error, :capture_date_unavailable}
    end

    test "window/2 says so too" do
      assert Timeline.window({:user, "01234567-89ab-7def-8123-456789abcdef"}, "2018-07-14") ==
               {:error, :capture_date_unavailable}
    end
  end
end
