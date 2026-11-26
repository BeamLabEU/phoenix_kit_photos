defmodule PhoenixKitPhotos.CSPInlineTagsTest do
  @moduledoc """
  The package works under a host Content-Security-Policy that allows inline code by nonce only
  (`script-src 'self' 'nonce-…'; style-src 'self' 'nonce-…'`).

  Its markup has no inline `<script>` / `<style>` and no inline event handler. Its styles ship
  with the hooks, so the bundle adds `<style>` elements to the page: each takes the page's nonce
  from core before it is inserted (`adoptStyle` in `assets/js/csp.js`, which calls core's
  `window.PhoenixKitInternals.adoptStyle` when the core in use has it).

  Modelled on core's `test/phoenix_kit_web/csp_inline_tags_test.exs`. `assets/test/csp.test.js`
  runs the stamping itself.
  """
  use ExUnit.Case, async: true

  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc|shortdoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  @bundle "priv/static/assets/phoenix_kit_photos.js"

  # No exemptions: nothing this package renders is cached or the same for everyone.
  @tag_opening ~r/<(script|style)\b[^>]*>/s

  # There is none today, and no helper for the nonce. One that is added reads it with
  # `PhoenixKitWeb.CSP.nonce/1`, feature-detected (core 3.7 has no such module): a small
  # `PhoenixKitPhotos.Web.CSP.nonce/1` that calls it with `apply/3` behind
  # `Code.ensure_loaded?/1` and `function_exported?/3`.
  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          not (opening =~ "CSP.nonce("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without a nonce (feature-detect `PhoenixKitWeb.CSP.nonce/1`, " <>
             "see AGENTS.md):\n" <> Enum.join(offenders, "\n")
  end

  @tag :tmp_dir
  test "the scan sees a tag in the middle of a line and one that closes on a later line", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "sample.ex")

    File.write!(path, """
    defmodule Sample do
      @moduledoc \"\"\"
      A `<style>` in documentation is prose.
      \"\"\"
      # <script> in a comment is prose too
      def a(assigns), do: ~H"<div><style>.a{}</style></div>"
      def b(assigns) do
        ~H\"\"\"
        <script
          defer
          src="/x.js"
        ></script>
        \"\"\"
      end
    end
    """)

    assert [{"<style>", 6}, {script, 9}] = tag_openings(path)
    assert script =~ "defer" and script =~ "src="
  end

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces around `=` for the
  # events a browser knows (a bare `on\w+ =` would also match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!("\\son[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]")
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `phx-` binding or a hook of the " <>
             "bundle):\n" <> Enum.join(offenders, "\n")
  end

  test "the handler pattern matches what it is meant to" do
    assert ~s[<ul onclick="x()">] =~ @handler
    assert ~s(<div onclick={@x}>) =~ @handler
    assert ~s(<img onerror = 'x'>) =~ @handler
    assert ~s[<a href="javascript:void(0)">] =~ @js_url
    refute ~s(<button data-bulk="trash" phx-click="go">) =~ @handler
    refute ~s(only = "x") =~ @handler
  end

  # The sources of the bundle, line by line. (The built file is one line per stylesheet row and
  # is checked as a whole below.)
  test "the JavaScript sources build no markup with an inline event handler" do
    offenders =
      for path <- js_sources(),
          {line, number} <- js_lines(path),
          line =~ ~r/[\s"'`<]on[a-z]+\s*=\s*\\?["'`]/ or line =~ ~r/javascript:/i,
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # A `<style>` the bundle creates is checked against the page's policy like any other: it is
  # stamped with the page's nonce before it is inserted, and never written as a string for
  # `innerHTML`, where a nonce is not applied. No `<script>` is created, and no `eval`:
  # `script-src` without 'unsafe-eval' blocks it.
  test "the sources stamp every <style> they create, create no <script>, evaluate no strings" do
    offenders =
      for path <- js_sources(),
          {line, number} <- js_lines(path),
          problem = source_problem(line),
          do: "#{path}:#{number} #{problem}"

    assert offenders == [], Enum.join(offenders, "\n")

    created =
      for path <- js_sources(),
          {line, _} <- js_lines(path),
          line =~ ~r/createElement\(\s*["'`]style["'`]\s*\)/,
          do: path

    # A scan that finds nothing proves nothing.
    assert Enum.sort(created) == [
             "assets/js/info_panel.js",
             "assets/js/stack_strip.js",
             "assets/js/timeline_css.js",
             "assets/js/viewer/video.js"
           ]
  end

  defp source_problem(line) do
    cond do
      line =~ ~r/createElement\(\s*["'`]style["'`]\s*\)/ and
          not (line =~ ~s[adoptStyle(document.createElement("style"))]) ->
        "creates a <style> that is not stamped (`adoptStyle` of assets/js/csp.js)"

      line =~ ~r/createElement\(\s*["'`]script["'`]\s*\)/ ->
        "creates a <script>"

      line =~ ~r/["'`]<\s*(?:style|script)\b/i ->
        "builds a <style>/<script> tag as a string"

      line =~ ~r/\beval\(|new Function\(/ ->
        "evaluates a string"

      true ->
        nil
    end
  end

  # What ships is the built file (`mix assets.deploy`, committed), with Leaflet and PhotoSwipe
  # inside it. Minified, so the helper has another name there: every `<style>` it creates is
  # the argument of a call, and core's function is asked for by name.
  test "the built bundle stamps every <style> it creates" do
    bundle = File.read!(@bundle)

    created = Regex.scan(~r/createElement\(\s*["'`]style["'`]\s*\)/, bundle)
    stamped = Regex.scan(~r/[\w$]\(document\.createElement\("style"\)\)/, bundle)

    assert length(created) == 4, "rebuild the bundle (`mix assets.deploy`) and update this count"

    assert length(stamped) == length(created),
           "the bundle is older than assets/js: run `mix assets.deploy`"

    assert bundle =~ "PhoenixKitInternals"
    assert bundle =~ ".adoptStyle"

    refute bundle =~ ~r/createElement\(\s*["'`]script["'`]\s*\)/
    refute bundle =~ ~r/["'`]<\s*(?:style|script)\b/i
    refute bundle =~ ~r/[^\w$.]eval\(|new Function\(/
    refute bundle =~ ~r/javascript:/i
    # Markup written as a string with a handler in it: `<a onclick="…">`.
    refute bundle =~ ~r/<[a-z][^<>`]*\son[a-z]+\s*=\s*\\?["']/
  end

  test "the bundle is the only JavaScript the package ships" do
    assert Path.wildcard("{lib,priv}/**/*.{js,ts,mjs}") == [@bundle]
  end

  defp js_sources, do: Enum.sort(Path.wildcard("assets/js/**/*.js"))

  # A file's lines without its comment lines.
  defp js_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _} -> line =~ ~r{^\s*(//|\*|/\*)} end)
  end

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  # Lines of the file with `@moduledoc`/`@doc` heredocs blanked: a tag in documentation is an
  # example, not markup.
  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
