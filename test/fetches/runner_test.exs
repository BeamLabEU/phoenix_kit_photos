defmodule PhoenixKitPhotos.Fetches.RunnerTest do
  @moduledoc """
  The runner ends what it starts: on cancel, on a stall and when its owner dies, the
  tool's whole process group goes, children included (yt-dlp's ffmpeg). stdout comes
  as lines, stderr goes to a file.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitPhotos.Fetches.Runner

  setup do
    dir = Path.join(System.tmp_dir!(), "pk_runner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp script(dir, body) do
    path = Path.join(dir, "tool.sh")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # Running, as opposed to gone or a zombie (dead, waiting for a parent to reap it: in a
  # container, PID 1 may never do that for an orphan).
  defp alive?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> stat |> String.split(") ", parts: 2) |> List.last() |> String.first() != "Z"
      _ -> false
    end
  end

  test "stdout as lines, stderr to a file, the exit status, a long line whole", %{dir: dir} do
    long = String.duplicate("x", 200_000)

    tool =
      script(dir, """
      echo one
      echo "to stderr" >&2
      printf '%s\\n' "#{long}"
      echo "args: $1 $2"
      exit 3
      """)

    assert {:ok, 3, out} = Runner.run(tool, ["a b", "c"], dir: dir)
    assert out == Enum.join(["one", long, "args: a b c"], "\n")
    assert Runner.stderr_tail(dir) == "to stderr\n"
    refute File.exists?(Path.join(dir, ".pgid"))
  end

  test "cancel ends the tool and the children it started", %{dir: dir} do
    tool = script(dir, "sleep 60 &\necho $! > child.pid\necho started\nwait\n")
    {runner, ref} = Runner.start(tool, [], dir: dir)

    assert_receive {^ref, {:line, "started"}}, 5_000
    child = dir |> Path.join("child.pid") |> File.read!() |> String.trim()
    assert alive?(child)

    Runner.cancel(runner)
    assert_receive {^ref, {:exit, :cancelled}}, 10_000
    Process.sleep(100)
    refute alive?(child)
  end

  test "a tool that says nothing for the stall time is ended", %{dir: dir} do
    tool = script(dir, "echo hello\nsleep 60\n")
    {_runner, ref} = Runner.start(tool, [], dir: dir, stall_ms: 300)
    assert_receive {^ref, {:line, "hello"}}, 5_000
    assert_receive {^ref, {:exit, :stalled}}, 10_000
  end

  test "an owner that dies takes the tool's group with it", %{dir: dir} do
    tool =
      script(dir, "sleep 60 &\necho $! > child.pid\necho $$ > leader.pid\necho started\nwait\n")

    test = self()

    owner =
      spawn(fn ->
        {_runner, ref} = Runner.start(tool, [], dir: dir)

        receive do
          {^ref, {:line, "started"}} -> send(test, :started)
        end

        Process.sleep(:infinity)
      end)

    assert_receive :started, 5_000
    leader = dir |> Path.join("leader.pid") |> File.read!() |> String.trim()
    child = dir |> Path.join("child.pid") |> File.read!() |> String.trim()
    assert alive?(child)

    Process.exit(owner, :kill)
    Process.sleep(4_000)
    refute alive?(leader)
    refute alive?(child)
  end

  test "run/3 gives up after its timeout and ends the tool", %{dir: dir} do
    tool = script(dir, "sleep 60 &\necho $! > child.pid\nwait\n")
    assert {:error, :timeout} = Runner.run(tool, [], dir: dir, timeout_ms: 300)
    Process.sleep(100)
    child = dir |> Path.join("child.pid") |> File.read!() |> String.trim()
    refute alive?(child)
  end

  test "kill_leftover/1 ends a tool a dead node left, and only one of the tools", %{dir: dir} do
    # A process whose command line is not one of the tools is left alone.
    port = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["60"])
    {:os_pid, pid} = Port.info(port, :os_pid)
    File.write!(Path.join(dir, ".pgid"), Integer.to_string(pid))

    Runner.kill_leftover(dir)
    assert alive?(Integer.to_string(pid))
    refute File.exists?(Path.join(dir, ".pgid"))
    Port.close(port)
    System.cmd("kill", ["-KILL", Integer.to_string(pid)])
  end
end
