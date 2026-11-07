defmodule PhoenixKitPhotos.ZipTest do
  use ExUnit.Case, async: true

  alias PhoenixKitPhotos.Zip

  @moduletag :tmp_dir

  defp archive(tmp_dir, files) do
    {:ok, sink} = Agent.start_link(fn -> [] end)

    write = fn data ->
      Agent.update(sink, &[data | &1])
      :ok
    end

    zip =
      Enum.reduce(files, Zip.new(), fn {name, content}, zip ->
        path = Path.join(tmp_dir, "in-#{System.unique_integer([:positive])}")
        File.write!(path, content)
        {:ok, zip} = Zip.add(zip, name, path, ~U[2021-03-04 05:06:08Z], write)
        zip
      end)

    write.(Zip.finish(zip))
    sink |> Agent.get(& &1) |> Enum.reverse() |> IO.iodata_to_binary()
  end

  test "what comes out opens, with the names and bytes that went in", %{tmp_dir: tmp_dir} do
    bytes = :crypto.strong_rand_bytes(3_000_000)

    zip =
      archive(tmp_dir, [{"IMG_0001.jpg", bytes}, {"Tõnis ja sõbrad.heic", "tere"}, {"empty", ""}])

    assert {:ok, files} = :zip.unzip(zip, [:memory])
    files = Map.new(files, fn {name, data} -> {List.to_string(name), data} end)
    assert files["IMG_0001.jpg"] == bytes
    assert files["empty"] == ""
    assert Map.values(files) |> Enum.member?("tere")
  end

  test "the archive tool agrees", %{tmp_dir: tmp_dir} do
    if System.find_executable("unzip") do
      path = Path.join(tmp_dir, "out.zip")
      File.write!(path, archive(tmp_dir, [{"a.jpg", "one"}, {"Tõnis.jpg", "two"}]))
      {output, status} = System.cmd("unzip", ["-t", path], stderr_to_stdout: true)
      assert status == 0, output
      assert output =~ "No errors detected"
    end
  end

  test "a reader who left stops the writing", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "in")
    File.write!(path, "x")
    assert {:error, :closed} = Zip.add(Zip.new(), "x", path, nil, fn _ -> {:error, :closed} end)
  end

  test "a file that is not there is an error, not a crash" do
    assert {:error, :enoent} = Zip.add(Zip.new(), "x", "/nonexistent/file", nil, fn _ -> :ok end)
  end
end
