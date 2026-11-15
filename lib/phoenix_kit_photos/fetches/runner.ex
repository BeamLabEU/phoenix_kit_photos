defmodule PhoenixKitPhotos.Fetches.Runner do
  @moduledoc """
  Runs one of the fetch tools as an operating-system process and makes sure it ends.

  `start/3` spawns a process linked to the caller (the owner) that opens the tool
  through a port and sends the owner each line of the tool's **stdout**:
  `{ref, {:line, line}}`, then `{ref, {:exit, status}}` once, where `status` is the exit
  code, `:stalled` (nothing said for `:stall_ms`), `:cancelled` (`cancel/1`) or
  `:too_much` (a line or the whole output over its limit), or `:too_big` (a file over
  `:file_limit`). The tool's **stderr** goes
  to a file (`stderr_tail/1` reads its end), so stdout carries only what is meant for
  machines: the tools' JSON and the marker lines the fetch asks for.

  ## The whole process group goes

  The BEAM starts every external program as the leader of a process group of its own
  (its pid is the group's id), and a tool starts others: yt-dlp runs ffmpeg to join
  video and audio. Closing the port ends none of them; an owner that dies leaves them
  running. So the runner traps exits, and on `cancel/1`, a stall, a too-long line or
  the owner's death it sends `TERM` to the group, waits a moment, then `KILL`. The
  group's id is written to `<dir>/.pgid` while it runs, so a node that died outright
  leaves a note: `kill_leftover/1` ends what it names, once it has checked the process
  is still one of the tools.

  The tool is started as `sh -c 'exec "$0" "$@" 2>>"$PKF_STDERR"' tool args…`: the
  shell sets up the stderr file and then becomes the tool, so the port's pid is the
  tool's. `PYTHONUNBUFFERED=1` makes both tools (Python) print each line as it happens,
  not in blocks.
  """

  require Logger

  @line_bytes 65_536
  @max_line_bytes 16 * 1024 * 1024
  @max_output_bytes 64 * 1024 * 1024
  @term_grace_ms 3_000

  @size_check_ms 1_000

  @type exit_status :: non_neg_integer() | :stalled | :cancelled | :too_much | :too_big

  @doc """
  Starts `exe` with `args` in `dir` (created; stderr goes to `<dir>/stderr.log`).
  `opts`: `:stall_ms` (default 10 minutes), `:file_limit` (`{directory, max_bytes}`:
  stop with `:too_big` when a file grows over the cap, checked each second, even while
  the owner is busy storing another file). Returns `{pid, ref}`.
  """
  @spec start(Path.t(), [String.t()], keyword()) :: {pid(), reference()}
  def start(exe, args, opts) do
    dir = Keyword.fetch!(opts, :dir)
    stall_ms = Keyword.get(opts, :stall_ms, 600_000)
    owner = self()
    ref = make_ref()
    File.mkdir_p!(dir)

    file_limit = Keyword.get(opts, :file_limit)
    pid = spawn_link(fn -> init(owner, ref, exe, args, dir, stall_ms, file_limit) end)
    {pid, ref}
  end

  @doc "Ends the tool (and everything it started). The owner then gets `{:exit, :cancelled}`."
  @spec cancel(pid()) :: :ok
  def cancel(pid) do
    send(pid, :cancel)
    :ok
  end

  @doc """
  Runs `exe` to the end and collects its stdout: `{:ok, status, stdout}`, or
  `{:error, :timeout}` after `:timeout_ms` (the tool is ended). For the look before
  fetching, whose answer is one JSON document.
  """
  @spec run(Path.t(), [String.t()], keyword()) ::
          {:ok, exit_status(), String.t()} | {:error, :timeout}
  def run(exe, args, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 90_000)
    {pid, ref} = start(exe, args, Keyword.put_new(opts, :stall_ms, timeout))
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(pid, ref, deadline, [])
  end

  defp collect(pid, ref, deadline, lines) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, {:line, line}} -> collect(pid, ref, deadline, [line | lines])
      {^ref, {:exit, status}} -> {:ok, status, lines |> Enum.reverse() |> Enum.join("\n")}
    after
      left ->
        cancel(pid)

        receive do
          {^ref, {:exit, _}} -> :ok
        after
          @term_grace_ms + 2_000 -> :ok
        end

        {:error, :timeout}
    end
  end

  @doc "The last `bytes` of what the tool wrote to stderr in `dir`."
  @spec stderr_tail(Path.t(), pos_integer()) :: String.t()
  def stderr_tail(dir, bytes \\ 8_192) do
    path = Path.join(dir, "stderr.log")

    case File.stat(path) do
      {:ok, %{size: size}} ->
        {:ok, io} = File.open(path, [:read, :binary])

        try do
          :file.position(io, max(size - bytes, 0))

          case IO.binread(io, bytes) do
            data when is_binary(data) -> data
            _ -> ""
          end
        after
          File.close(io)
        end

      _ ->
        ""
    end
  end

  @doc """
  Ends a tool a dead node left running for `dir` (see the moduledoc), if its
  `.pgid` note names a process that is still yt-dlp, gallery-dl or ffmpeg.
  """
  @spec kill_leftover(Path.t()) :: :ok
  def kill_leftover(dir) do
    note = Path.join(dir, ".pgid")

    with {:ok, text} <- File.read(note),
         {pgid, _} <- Integer.parse(String.trim(text)),
         true <- ours?(pgid) do
      Logger.info("[Fetches] ending a fetch tool left running (process group #{pgid})")
      kill_group(pgid)
    end

    File.rm(note)
    :ok
  end

  defp ours?(pid) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, cmdline} ->
        String.contains?(cmdline, ["yt-dlp", "yt_dlp", "gallery-dl", "gallery_dl", "ffmpeg"])

      _ ->
        false
    end
  end

  # ── The runner process ──────────────────────────────────────────────────

  defp init(owner, ref, exe, args, dir, stall_ms, file_limit) do
    Process.flag(:trap_exit, true)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:line, @line_bytes},
        {:cd, dir},
        {:env,
         [
           {~c"PYTHONUNBUFFERED", ~c"1"},
           {~c"PKF_STDERR", String.to_charlist(Path.join(dir, "stderr.log"))}
         ]},
        {:args, ["-c", ~s(exec "$0" "$@" 2>>"$PKF_STDERR"), exe | args]}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    File.write(Path.join(dir, ".pgid"), Integer.to_string(os_pid))

    state = %{
      owner: owner,
      ref: ref,
      port: port,
      pgid: os_pid,
      dir: dir,
      stall_ms: stall_ms,
      file_limit: file_limit,
      last_output: System.monotonic_time(:millisecond),
      next_check: System.monotonic_time(:millisecond) + @size_check_ms,
      partial: [],
      partial_bytes: 0,
      total: 0
    }

    loop(state)
  end

  defp loop(state) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= state.next_check and oversized?(state.file_limit) ->
        stop(state, :too_big)

      now - state.last_output >= state.stall_ms ->
        stop(state, :stalled)

      true ->
        state =
          if now >= state.next_check,
            do: %{state | next_check: now + @size_check_ms},
            else: state

        wait = min(state.next_check - now, state.stall_ms - (now - state.last_output))
        receive_output(state, wait)
    end
  end

  defp oversized?(nil), do: false

  defp oversized?({dir, max_bytes}) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.any?(names, &oversized_file?(Path.join(dir, &1), max_bytes))

      _ ->
        false
    end
  end

  defp oversized_file?(path, max_bytes) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} -> size > max_bytes
      _ -> false
    end
  end

  defp receive_output(%{port: port} = state, wait) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = IO.iodata_to_binary(Enum.reverse([chunk | state.partial]))
        # The whole line counts, its earlier `:noeol` parts too.
        state = %{
          state
          | partial: [],
            partial_bytes: 0,
            total: state.total + byte_size(line),
            last_output: System.monotonic_time(:millisecond)
        }

        if state.total > @max_output_bytes do
          stop(state, :too_much)
        else
          send(state.owner, {state.ref, {:line, line}})
          loop(state)
        end

      {^port, {:data, {:noeol, chunk}}} ->
        bytes = state.partial_bytes + byte_size(chunk)

        if bytes > @max_line_bytes do
          stop(state, :too_much)
        else
          loop(%{
            state
            | partial: [chunk | state.partial],
              partial_bytes: bytes,
              last_output: System.monotonic_time(:millisecond)
          })
        end

      {^port, {:exit_status, status}} ->
        finish(state, status)

      :cancel ->
        stop(state, :cancelled)

      {:EXIT, owner, _reason} when owner == state.owner ->
        kill_group(state.pgid)
        File.rm(Path.join(state.dir, ".pgid"))
        exit(:normal)

      {:EXIT, _other, _reason} ->
        loop(state)
    after
      wait -> loop(state)
    end
  end

  defp stop(state, why) do
    kill_group(state.pgid, state.port)
    finish(state, why)
  end

  defp finish(state, status) do
    # Whatever the tool left in its group (an ffmpeg it started) goes with it.
    if is_integer(status), do: signal_group(state.pgid, "KILL")
    File.rm(Path.join(state.dir, ".pgid"))
    send(state.owner, {state.ref, {:exit, status}})
    :ok
  end

  # TERM to the group, then KILL once the leader is gone or the grace is over. With the
  # port, its exit status says when the leader is gone; without (a leftover), the grace.
  defp kill_group(pgid, port \\ nil) do
    signal_group(pgid, "TERM")

    if port do
      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        @term_grace_ms -> :ok
      end
    else
      Process.sleep(@term_grace_ms)
    end

    signal_group(pgid, "KILL")
  end

  defp signal_group(pgid, signal) do
    System.cmd("kill", ["-#{signal}", "--", "-#{pgid}"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end
end
