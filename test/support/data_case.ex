defmodule PhoenixKitPhotos.DataCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitPhotos.TestRepo

  using do
    quote do
      alias PhoenixKit.Modules.Storage.Libraries
      alias PhoenixKit.Users.Auth.Scope
      alias PhoenixKitPhotos.TestRepo
      alias PhoenixKitPhotos.Timeline

      import PhoenixKitPhotos.DataCase
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  def media_uuid, do: Libraries.media_uuid()

  def user_fixture(email) do
    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(%{email: email})
      |> TestRepo.insert()

    user
  end

  def scope_for(%User{} = user, roles \\ []) do
    %Scope{user: user, authenticated?: true, cached_roles: roles}
  end

  def file_fixture(user, attrs) do
    defaults = %{
      original_file_name: "IMG_0001.jpg",
      file_name: "img.jpg",
      mime_type: "image/jpeg",
      file_type: "image",
      ext: "jpg",
      file_checksum: random_hex(),
      user_file_checksum: random_hex(),
      size: 1000,
      width: 4000,
      height: 3000,
      status: "active",
      system_managed: false,
      user_uuid: user.uuid,
      library_uuid: media_uuid(),
      taken_on: ~D[2018-07-14],
      taken_at: ~U[2018-07-14 12:00:00Z],
      taken_at_source: "exif"
    }

    attrs = Map.merge(defaults, attrs)
    {width, attrs} = Map.pop(attrs, :width)
    {height, attrs} = Map.pop(attrs, :height)
    {edit_state, attrs} = Map.pop(attrs, :edit_state)

    changeset =
      %StorageFile{}
      |> StorageFile.changeset(attrs)
      |> Ecto.Changeset.put_change(:width, width)
      |> Ecto.Changeset.put_change(:height, height)

    changeset =
      if edit_state,
        do: Ecto.Changeset.put_change(changeset, :edit_state, edit_state),
        else: changeset

    {:ok, file} = TestRepo.insert(changeset)
    file
  end

  def library_fixture(user) do
    alias PhoenixKit.Modules.Storage.Library
    suffix = System.unique_integer([:positive])

    %Library{}
    |> Library.create_user_changeset(%{
      name: "Photos #{suffix}",
      owner_uuid: user.uuid,
      key_prefix: "photos-#{suffix}",
      slug: "photos-#{suffix}"
    })
    |> TestRepo.insert!()
  end

  def member_fixture(library, user) do
    alias PhoenixKit.Modules.Storage.LibraryMember

    %LibraryMember{}
    |> LibraryMember.changeset(%{
      library_uuid: library.uuid,
      user_uuid: user.uuid,
      role: "viewer"
    })
    |> TestRepo.insert!()
  end

  def variants_fixture(library) do
    alias PhoenixKit.Modules.Storage.{Dimension, VariantSet}
    set = TestRepo.insert!(%VariantSet{name: "Variants #{library.uuid}"})

    for {name, width, crop} <- [{"thumbnail", 200, true}, {"large", 800, false}] do
      TestRepo.insert!(%Dimension{
        variant_set_uuid: set.uuid,
        name: name,
        width: width,
        height: width,
        enabled: true,
        applies_to: "image",
        format: "jpg",
        maintain_aspect_ratio: not crop
      })
    end

    library |> Ecto.Changeset.change(variant_set_uuid: set.uuid) |> TestRepo.update!()
  end

  defp random_hex, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
