defmodule PhoenixKitPhotos.UploadsTest do
  @moduledoc """
  What the uploader asks of the server: who may add to a library, which files it
  takes, and storing a finished upload (new, again, in another library, trashed,
  refused). A real local bucket, the real storage pipeline; only the browser is missing.
  """
  use PhoenixKitPhotos.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Settings
  alias PhoenixKitPhotos.Uploads

  @buckets_cache :phoenix_kit_buckets_cache
  # A 1x1 PNG.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    # Trashing a file announces it on PhoenixKit's internal PubSub.
    start_supervised!(PhoenixKit.PubSub.Manager)

    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_photos_uploads_#{n}")
    dir = Path.join(System.tmp_dir!(), "pk_photos_src_#{n}")
    File.mkdir_p!(dir)

    TestRepo.update_all(Bucket, set: [enabled: false])

    {:ok, _} =
      Storage.create_bucket(%{
        name: "uploads-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
      File.rm_rf(dir)
    end)

    owner = user_fixture("owner-#{n}@example.com")
    %{n: n, dir: dir, owner: owner, library: library_fixture(owner)}
  end

  defp file!(ctx, bytes \\ @png, name \\ "a.png") do
    path = Path.join(ctx.dir, "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, bytes)
    path
  end

  defp entry(name \\ "a.png", type \\ "image/png"), do: %{client_name: name, client_type: type}

  defp as_member(ctx, role) do
    user = user_fixture("#{role}-#{ctx.n}-#{System.unique_integer([:positive])}@example.com")
    member_fixture(ctx.library, user, role)
    scope_for(user)
  end

  describe "accept/0 and max_file_size/0" do
    test "photos and videos a phone makes, and nothing that can carry a script" do
      accept = Uploads.accept()

      for ext <-
            ~w(.jpg .jpeg .png .gif .webp .heic .heif .avif .tif .tiff .bmp .mp4 .mov .webm .3gp),
          do: assert(ext in accept)

      for ext <- ~w(.svg .html .pdf .exe .js .zip .m4v .mkv), do: refute(ext in accept)
    end

    test "the size limit is the site's setting" do
      assert Uploads.max_file_size() == 500 * 1_048_576

      {:ok, _} = Settings.update_setting("storage_max_upload_size_mb", "12")
      assert Uploads.max_file_size() == 12 * 1_048_576
    end
  end

  describe "can_upload?/2" do
    test "a user library: its owner, a manager and a contributor; not a viewer or a stranger",
         ctx do
      assert Uploads.can_upload?(scope_for(ctx.owner), ctx.library.uuid)
      assert Uploads.can_upload?(as_member(ctx, "manager"), ctx.library.uuid)
      assert Uploads.can_upload?(as_member(ctx, "contributor"), ctx.library.uuid)

      refute Uploads.can_upload?(as_member(ctx, "viewer"), ctx.library.uuid)
      stranger = user_fixture("stranger-#{ctx.n}@example.com")
      refute Uploads.can_upload?(scope_for(stranger), ctx.library.uuid)
    end

    test "nobody who is not signed in, and nothing that is not a library", ctx do
      refute Uploads.can_upload?(nil, ctx.library.uuid)
      refute Uploads.can_upload?(%Scope{user: nil}, ctx.library.uuid)
      refute Uploads.can_upload?(scope_for(ctx.owner), Ecto.UUID.generate())
      refute Uploads.can_upload?(scope_for(ctx.owner), nil)
    end

    test "a library in the trash has no one", ctx do
      ctx.library
      |> Ecto.Changeset.change(trashed_at: DateTime.utc_now(:second))
      |> TestRepo.update!()

      refute Uploads.can_upload?(scope_for(ctx.owner), ctx.library.uuid)
    end

    test "Media: an admin and a holder of media, not everyone", ctx do
      user = user_fixture("plain-#{ctx.n}@example.com")
      media = media_uuid()

      refute Uploads.can_upload?(scope_for(user), media)
      assert Uploads.can_upload?(scope_for(user, ["Admin"]), media)
      assert Uploads.can_upload?(scope_for(user, ["Owner"]), media)

      holder = %{scope_for(user) | cached_permissions: MapSet.new(["media"])}
      assert Uploads.can_upload?(holder, media)
    end
  end

  describe "store/4" do
    test "a new file is added to the library, for the uploader", ctx do
      scope = scope_for(ctx.owner)

      assert {:added, file} = Uploads.store(file!(ctx), entry(), scope, ctx.library.uuid)

      assert file.library_uuid == ctx.library.uuid
      assert file.user_uuid == ctx.owner.uuid
      assert file.original_file_name == "a.png"
      assert file.file_type == "image"
      assert file.mime_type == "image/png"
    end

    test "the same bytes again are a duplicate, not a second file", ctx do
      scope = scope_for(ctx.owner)
      assert {:added, first} = Uploads.store(file!(ctx), entry(), scope, ctx.library.uuid)

      assert {:duplicate, again} =
               Uploads.store(file!(ctx), entry("b.png"), scope, ctx.library.uuid)

      assert again.uuid == first.uuid
    end

    test "a contributor adds in their own name", ctx do
      contributor = as_member(ctx, "contributor")

      assert {:added, file} = Uploads.store(file!(ctx), entry(), contributor, ctx.library.uuid)
      assert file.user_uuid == contributor.user.uuid
      assert file.library_uuid == ctx.library.uuid
    end

    test "a file that was in the trash is wanted again", ctx do
      scope = scope_for(ctx.owner)
      {:added, file} = Uploads.store(file!(ctx), entry(), scope, ctx.library.uuid)
      {:ok, _} = Storage.trash_file(file)
      assert Storage.get_file(file.uuid).status == "trashed"

      assert {:added, restored} = Uploads.store(file!(ctx), entry(), scope, ctx.library.uuid)
      assert restored.uuid == file.uuid
      assert restored.status != "trashed"
    end

    test "someone who may not add stores nothing", ctx do
      stranger = scope_for(user_fixture("nobody-#{ctx.n}@example.com"))
      viewer = as_member(ctx, "viewer")
      path = file!(ctx)

      assert {:error, :not_allowed} = Uploads.store(path, entry(), stranger, ctx.library.uuid)
      assert {:error, :not_allowed} = Uploads.store(path, entry(), viewer, ctx.library.uuid)
      assert {:error, :not_allowed} = Uploads.store(path, entry(), nil, ctx.library.uuid)
      assert Storage.list_files() == []
    end

    test "an SVG, a document or a program is not a photo", ctx do
      scope = scope_for(ctx.owner)

      for {name, type} <- [
            {"x.svg", "image/svg+xml"},
            {"x.svg", "image/png"},
            {"x.pdf", "application/pdf"},
            {"x.exe", "application/octet-stream"},
            {"x.html", "text/html"},
            {"photo.png.exe", "image/png"}
          ] do
        assert {:error, :unsupported_type} =
                 Uploads.store(file!(ctx, "<svg/>"), entry(name, type), scope, ctx.library.uuid)
      end

      assert Storage.list_files() == []
    end

    test "a file that went missing is an error, never a raise", ctx do
      scope = scope_for(ctx.owner)

      assert {:error, :file_missing} =
               Uploads.store(Path.join(ctx.dir, "gone.png"), entry(), scope, ctx.library.uuid)
    end

    test "a name with a path in it is stored as its last part", ctx do
      scope = scope_for(ctx.owner)

      assert {:added, file} =
               Uploads.store(file!(ctx), entry("../../etc/passwd.png"), scope, ctx.library.uuid)

      assert file.original_file_name == "passwd.png"
    end
  end

  describe "names and types" do
    test "clean_name/1" do
      assert Uploads.clean_name("IMG_0001.HEIC") == "IMG_0001.HEIC"
      assert Uploads.clean_name("C:\\Users\\me\\a.png") == "a.png"
      assert Uploads.clean_name("a\u0000b.png") == "ab.png"
      assert Uploads.clean_name("..") == "upload"
      assert Uploads.clean_name("") == "upload"
      assert Uploads.clean_name(nil) == "upload"

      long = String.duplicate("x", 400) <> ".jpg"
      cleaned = Uploads.clean_name(long)
      assert String.length(cleaned) == 255
      assert String.ends_with?(cleaned, ".jpg")
    end

    test "mime_for/2: the browser's word, else the extension's" do
      assert Uploads.mime_for(%{client_type: "image/jpeg"}, "a.jpg") == "image/jpeg"
      assert Uploads.mime_for(%{client_type: "IMAGE/HEIC"}, "a.heic") == "image/heic"
      # Desktop Chrome says nothing about a HEIC.
      assert Uploads.mime_for(%{client_type: ""}, "IMG_1.HEIC") == "image/heic"

      assert Uploads.mime_for(%{client_type: "application/octet-stream"}, "v.mov") ==
               "video/quicktime"

      assert Uploads.mime_for(%{}, "a.webp") == "image/webp"
    end
  end

  describe "messages" do
    test "every reason has words" do
      for reason <- [:too_large, :not_accepted, :too_many_files, :something_else],
          do: assert(is_binary(Uploads.entry_error(reason)) and Uploads.entry_error(reason) != "")

      for reason <- [:not_allowed, :unsupported_type, :file_missing, :failed, {:odd, 1}],
          do:
            assert(
              is_binary(Uploads.error_message(reason)) and Uploads.error_message(reason) != ""
            )

      assert Uploads.entry_error(:too_large) =~ "500"
    end
  end
end
