defmodule PhoenixKitPhotos.SyntheticLibrary do
  @moduledoc """
  Rollback-only benchmark fixture for a 10k or 100k timeline.

  Call `seed!/4` with a repo already checked out in SQL Sandbox, a fixture
  user and a fixture library. No originals or stored variants are created;
  browser tests must supply synthetic images. The first day has 1,200 files.
  The rest span monthly buckets, with 45% 4:3, 35% 3:2, 15% portrait and
  5% panoramic dimensions. Never run this outside a sandbox transaction.
  """
  alias PhoenixKit.Modules.Storage.File, as: StorageFile

  def seed!(repo, user, library, count \\ 10_000) when count > 0 do
    now = DateTime.utc_now(:second)

    rows =
      for n <- 0..(count - 1) do
        month = if n < 1200, do: 0, else: div(n - 1200, 100) + 1
        date = Date.new!(2010 + div(month, 12), rem(month, 12) + 1, 1)
        {width, height} = dimensions(n)
        checksum = :crypto.hash(:sha256, "#{library.uuid}:#{n}") |> Base.encode16(case: :lower)

        %{
          uuid: UUIDv7.generate(),
          original_file_name: "photo-#{n}.jpg",
          file_name: "photo-#{n}.jpg",
          mime_type: "image/jpeg",
          file_type: "image",
          ext: "jpg",
          size: 1000,
          width: width,
          height: height,
          status: "active",
          system_managed: false,
          user_uuid: user.uuid,
          library_uuid: library.uuid,
          file_checksum: checksum,
          user_file_checksum: checksum,
          taken_on: date,
          taken_at: DateTime.new!(date, ~T[00:00:00]) |> DateTime.add(rem(n, 1200)),
          taken_at_source: "exif",
          inserted_at: now,
          updated_at: now
        }
      end

    for batch <- Enum.chunk_every(rows, 500), do: repo.insert_all(StorageFile, batch)
    :ok
  end

  defp dimensions(n) do
    case rem(n, 20) do
      n when n < 9 -> {4000, 3000}
      n when n < 16 -> {6000, 4000}
      n when n < 19 -> {1080, 1920}
      _ -> {8000, 2000}
    end
  end
end
