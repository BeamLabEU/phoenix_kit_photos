defmodule PhoenixKitPhotosTest do
  use ExUnit.Case, async: true

  alias PhoenixKitPhotos, as: MT

  describe "PhoenixKit.Module registration" do
    test "declares the key the Hex package name derives" do
      # KnownPackages strips the "phoenix_kit_" prefix from the package name to
      # get the catalog key, so these two must agree or the admin catalog and
      # the installed module disagree about what this is.
      assert MT.module_key() == "photos"
      assert MT.module_name() == "Photos"
    end

    test "is discoverable without configuration" do
      # ModuleDiscovery scans this persisted attribute rather than loading the
      # module, so its absence means zero-config discovery silently fails.
      assert {:phoenix_kit_module, [true]} in MT.__info__(:attributes)
    end

    test "requires the storage module" do
      assert MT.required_modules() == ["storage"]
    end

    test "reports its version" do
      assert MT.version() == Mix.Project.config()[:version]
    end
  end

  describe "js_sources/0" do
    test "declares a bundle with a unique global and a priv-relative path" do
      assert [%{app: app, file: file, global: global}] = MT.js_sources()
      assert app == :phoenix_kit_photos
      assert file == "static/assets/phoenix_kit_photos.js"
      assert global == "PhoenixKitPhotosHooks"
      # The compiler emits this as window.<global>, so it must be a valid JS identifier.
      assert Regex.match?(~r/^[A-Za-z_$][A-Za-z0-9_$]*$/, global)
    end

    test "the declared bundle actually exists in priv" do
      [%{file: file}] = MT.js_sources()
      path = Path.join(:code.priv_dir(:phoenix_kit_photos), file)

      assert File.exists?(path),
             "run `mix assets.build` — js_sources/0 declares a prebuilt bundle, it does not build one"
    end

    test "the bundle assigns the global it promises" do
      [%{file: file, global: global}] = MT.js_sources()
      contents = File.read!(Path.join(:code.priv_dir(:phoenix_kit_photos), file))
      assert contents =~ global
      # Hook names are folded last-write-wins across bundles, so this one must
      # be namespaced enough not to collide with core's.
      assert contents =~ "PhotoTimeline"
    end
  end

  describe "css_sources/0" do
    test "contributes source roots for both Hex and path-dep installs" do
      sources = MT.css_sources()
      assert :phoenix_kit_photos in sources
      assert Enum.any?(sources, &(is_binary(&1) and String.starts_with?(&1, "/")))
    end

    test "the absolute root actually contains this package's templates" do
      root = Enum.find(MT.css_sources(), &is_binary/1)
      assert File.exists?(Path.join(root, "lib/phoenix_kit_photos"))
    end
  end

  describe "permission_metadata/0" do
    test "is specified before any route ships" do
      meta = MT.permission_metadata()
      assert meta.key == "photos"
      assert [%{key: "view_any"}] = meta.sub_permissions
    end
  end
end
