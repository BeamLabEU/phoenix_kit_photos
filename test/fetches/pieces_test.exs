defmodule PhoenixKitPhotos.Fetches.PiecesTest do
  @moduledoc """
  The pure parts of fetching from a link: what counts as a link, cookies kept to one
  site, a title/author/date out of each site's own fields, the tools' command lines and
  what their output means, why a fetch failed, and a stored file's name.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.CaptureDate
  alias PhoenixKitPhotos.Fetches.{CookiesTxt, Errors, FetchJob, GalleryDl, Link, Meta, YtDlp}

  describe "Link" do
    test "one http(s) link, with the sentence around it dropped" do
      assert {:ok, "https://www.flickr.com/photos/x/1"} =
               Link.parse("  https://www.flickr.com/photos/x/1 ")

      assert {:ok, "https://youtu.be/abc"} = Link.parse("look at this: https://youtu.be/abc.")

      assert {:ok, "https://en.wikipedia.org/wiki/A_(b)"} =
               Link.parse("https://en.wikipedia.org/wiki/A_(b)")

      assert {:ok, "https://example.com/a"} = Link.parse("(https://example.com/a)")
    end

    test "not a link: no URL, two URLs, other schemes, credentials, no host" do
      assert :error = Link.parse("just words")
      assert :error = Link.parse("https://a.com/1 https://b.com/2")
      assert :error = Link.parse("ftp://example.com/a.jpg")
      assert :error = Link.parse("file:///etc/passwd")
      assert :error = Link.parse("https://user:pw@example.com/a")
      assert :error = Link.parse("http://localhost/a")
      assert :error = Link.parse(nil)
      assert :error = Link.parse("https://example.com/" <> String.duplicate("a", 2_100))
    end

    test "the site is the host without www" do
      assert Link.site("https://www.Flickr.com/x") == "flickr.com"
      assert Link.site("https://old.reddit.com/r/x") == "old.reddit.com"
    end

    test "a login is kept under the registered domain, with known aliases" do
      assert Link.login_site("https://old.reddit.com/r/x") == "reddit.com"
      assert Link.login_site("https://www.instagram.com/p/x") == "instagram.com"
      assert Link.login_site("https://twitter.com/a/status/1") == "x.com"
      assert Link.login_site("https://youtu.be/abc") == "youtube.com"
      assert Link.login_site("www.bbc.co.uk") == "bbc.co.uk"
      assert Link.login_site("instagram.com") == "instagram.com"
      assert Link.login_site("not a host") == nil
    end
  end

  describe "CookiesTxt" do
    @export Enum.join(
              [
                "# Netscape HTTP Cookie File",
                "# a comment",
                ".instagram.com\tTRUE\t/\tTRUE\t1893456000\tsessionid\tsecret1",
                "#HttpOnly_.www.instagram.com\tTRUE\t/\tTRUE\t0\tcsrftoken\tsecret2",
                ".mybank.com\tTRUE\t/\tTRUE\t1893456000\tsession\tbanksecret",
                ".com\tTRUE\t/\tFALSE\t0\tsupercookie\tx",
                "garbage line",
                ""
              ],
              "\n"
            )

    test "keeps only the site's cookies, HttpOnly ones included" do
      assert {:ok, text, 2} = CookiesTxt.for_site(@export, "instagram.com")
      assert text =~ "sessionid\tsecret1"
      assert text =~ "#HttpOnly_.www.instagram.com"
      refute text =~ "banksecret"
      refute text =~ "supercookie"
      assert String.starts_with?(text, "# Netscape HTTP Cookie File\n")
    end

    test "a parent domain counts, a bare top-level domain never" do
      lines = ".reddit.com\tTRUE\t/\tTRUE\t0\ta\tb\n.com\tTRUE\t/\tTRUE\t0\tc\td\n"
      assert {:ok, text, 1} = CookiesTxt.for_site(lines, "old.reddit.com")
      refute text =~ "\tc\td"
    end

    test "nothing for the site, or not a cookies.txt at all" do
      assert {:error, :empty} = CookiesTxt.for_site(@export, "x.com")

      assert {:error, :not_cookies_txt} =
               CookiesTxt.for_site("sessionid=abc; csrftoken=def", "x.com")

      assert {:error, :not_cookies_txt} = CookiesTxt.for_site("", "x.com")
    end
  end

  describe "Meta" do
    test "a title from the title, else the first line of the text" do
      assert Meta.title(%{"title" => "  Harbour "}) == "Harbour"
      assert Meta.title(%{"title" => "", "text" => "Line one\nline two"}) == "Line one"
      assert Meta.title(%{}) == nil
      assert String.length(Meta.title(%{"title" => String.duplicate("a", 500)})) == 200
    end

    test "an author from each site's own shape" do
      assert Meta.author(%{"uploader" => "jawed"}) == "jawed"
      assert Meta.author(%{"owner" => %{"username" => "NASA HQ PHOTO"}}) == "NASA HQ PHOTO"

      assert Meta.author(%{"author" => %{"displayName" => "Bluesky", "handle" => "bsky.app"}}) ==
               "Bluesky"

      assert Meta.author(%{"user" => "Bdk"}) == "Bdk"
      assert Meta.author(%{"user" => %{"nsid" => "1"}}) == nil
    end

    test "a date from a timestamp, an upload date or gallery-dl's date" do
      assert Meta.posted_at(%{"timestamp" => 1_114_313_512}) == ~N[2005-04-24 03:31:52]
      assert Meta.posted_at(%{"upload_date" => "20050424"}) == ~N[2005-04-24 00:00:00]
      assert Meta.posted_at(%{"date" => "2010-03-14 17:20:20"}) == ~N[2010-03-14 17:20:20]
      assert Meta.posted_at(%{"date" => "yesterday"}) == nil
      assert Meta.posted_at(%{}) == nil
    end
  end

  describe "YtDlp" do
    @opts [proxy: "http://127.0.0.1:4750", max_items: 50]

    test "every command goes through the proxy, without the user's config" do
      for args <- [
            YtDlp.probe_args("https://v/1", @opts),
            YtDlp.fetch_args("https://v/1", "/w", @opts)
          ] do
        assert ["--proxy", "http://127.0.0.1:4750", "--ignore-config" | _] = args
        assert Enum.take(args, -2) == ["--", "https://v/1"]
        assert "--no-playlist" in args
      end
    end

    test "the look lists a playlist flat, one past the limit" do
      args = YtDlp.probe_args("https://v/1", @opts)
      assert "--flat-playlist" in args
      assert "1:51" == after_flag(args, "--playlist-items")
    end

    test "quality: 1080p by default, best on request; picked items; cookies" do
      default = YtDlp.fetch_args("https://v/1", "/w", @opts)
      assert after_flag(default, "-S") == "res:1080"
      assert after_flag(default, "--playlist-items") == "1:50"

      best =
        YtDlp.fetch_args(
          "https://v/1",
          "/w",
          @opts ++ [quality: "best", items: [2, 5], cookies: "/w/cookies.txt"]
        )

      refute "-S" in best
      assert after_flag(best, "--playlist-items") == "2,5"
      assert after_flag(best, "--cookies") == "/w/cookies.txt"
      assert after_flag(best, "--merge-output-format") == "mp4"
      assert after_flag(best, "-P") == "/w"
    end

    test "what a fetch prints" do
      assert {:item, 3} = YtDlp.parse_line(~s(PKF_ITEM 3 "abc"))
      assert {:item, 1} = YtDlp.parse_line(~s(PKF_ITEM 0 "abc"))

      assert {:progress, %{bytes: 10, total: 100, speed: 5, eta: 2, finished: false}} =
               YtDlp.parse_line(
                 ~s(PKF_DL {"downloaded_bytes": 10, "total_bytes": 100, "speed": 5.5, "eta": 2, "status": "downloading"})
               )

      assert {:progress, %{total: 999}} =
               YtDlp.parse_line(~s(PKF_DL {"downloaded_bytes": 1, "total_bytes_estimate": 999.4}))

      assert {:postprocess, "started", "Merger"} = YtDlp.parse_line("PKF_PP started Merger")

      assert {:file, "/w/a.mp4", %{"title" => "T"}} =
               YtDlp.parse_line(~s(PKF_FILE {"filepath": "/w/a.mp4", "title": "T"}))

      assert :other = YtDlp.parse_line("[download] Destination: x")
      assert :other = YtDlp.parse_line("PKF_DL not json")
    end

    test "a video's info, with sizes for 1080p and for the best" do
      doc = %{
        "title" => "Zoo",
        "uploader" => "jawed",
        "timestamp" => 1_114_313_512,
        "duration" => 19,
        "formats" => [
          %{"vcodec" => "none", "acodec" => "opus", "abr" => 128, "filesize" => 100},
          %{"vcodec" => "vp9", "acodec" => "none", "height" => 1080, "filesize" => 1_000},
          %{
            "vcodec" => "vp9",
            "acodec" => "none",
            "height" => 2160,
            "filesize_approx" => 4_000.0
          },
          %{"vcodec" => "avc1", "acodec" => "mp4a", "height" => 360, "tbr" => 500}
        ]
      }

      info = YtDlp.probe_info(doc, 50)
      assert info["kind"] == "single"
      assert info["title"] == "Zoo"
      assert info["author"] == "jawed"
      assert info["posted_at"] == "2005-04-24T03:31:52"
      assert info["sizes"] == %{"default" => 1_100, "best" => 4_100}
      assert info["heights"] == %{"default" => 1080, "best" => 2160}
      assert [%{"index" => 1}] = info["entries"]
    end

    test "a playlist is a collection, cut at the limit" do
      entries = for i <- 1..4, do: %{"id" => "v#{i}", "title" => "Video #{i}", "duration" => 60}

      doc = %{
        "_type" => "playlist",
        "title" => "List",
        "uploader" => "Tim",
        "playlist_count" => 17,
        "entries" => entries
      }

      info = YtDlp.probe_info(doc, 3)
      assert info["kind"] == "collection"
      assert info["count"] == 17
      assert info["more"] == true
      assert Enum.map(info["entries"], & &1["index"]) == [1, 2, 3]
    end
  end

  describe "GalleryDl" do
    @opts [proxy: "http://127.0.0.1:4750", max_items: 50]

    test "through the proxy, without the user's config, metadata written per file" do
      args = GalleryDl.fetch_args("https://p/1", "/w/files", @opts ++ [keys: ["a", "b"]])
      assert ["--proxy", "http://127.0.0.1:4750", "--config-ignore" | _] = args
      assert after_flag(args, "-D") == "/w/files"
      assert "--write-metadata" in args
      assert after_flag(args, "--range") == "1-51"
      assert Enum.take(args, -2) == ["--", "https://p/1"]
    end

    test "the chosen files go in by name, each one a JSON string literal" do
      assert ["--filter", ~s(filename in {"a", "b"})] = GalleryDl.filter(["a", "b", "a"])
      # A name made to end the expression stays inside its string.
      assert ["--filter", filter] =
               GalleryDl.filter([~S|x"} or __import__("os").system("id") or {"|])

      assert filter == ~S|filename in {"x\"} or __import__(\"os\").system(\"id\") or {\""}|
      assert [] = GalleryDl.filter(nil)
      assert [] = GalleryDl.filter([])
    end

    test "the look's messages: files with their key, a collection, or nothing" do
      messages = [
        [2, %{"category" => "flickr"}],
        [
          3,
          "https://i/1.jpg",
          %{
            "category" => "flickr",
            "filename" => "f1",
            "extension" => "jpg",
            "title" => "One",
            "owner" => %{"username" => "Ann"},
            "date" => "2020-01-02 03:04:05"
          }
        ],
        [
          3,
          "https://i/2.mp4",
          %{"filename" => "f2", "extension" => "mp4", "thumbnail" => "https://i/2.jpg"}
        ]
      ]

      info = GalleryDl.probe_info(messages, 50)
      assert info["kind"] == "collection"
      assert info["video"] == true

      assert [
               %{
                 "key" => "f1",
                 "kind" => "image",
                 "thumbnail" => "https://i/1.jpg",
                 "author" => "Ann",
                 "posted_at" => "2020-01-02T03:04:05"
               },
               %{"key" => "f2", "kind" => "video", "thumbnail" => "https://i/2.jpg"}
             ] = info["entries"]

      assert {:error, :nothing} = GalleryDl.probe_info([[2, %{}]], 50)

      assert {:delegate, :yt_dlp} =
               GalleryDl.probe_info([[3, "ytdl:https://v.redd.it/x", %{}]], 50)
    end

    test "what a fetch prints" do
      assert {:item, "flickr"} = GalleryDl.parse_line("PKF_ITEM flickr")
      assert {:file, "/w/a b.jpg"} = GalleryDl.parse_line(~s(PKF_FILE "/w/a b.jpg"))
      assert :other = GalleryDl.parse_line("/w/a b.jpg")
    end
  end

  describe "Errors" do
    test "codes from what the tools say" do
      assert Errors.classify("ERROR: Unsupported URL: https://x") == "unsupported"
      assert Errors.classify("[gallery-dl][error] Unsupported URL 'https://x'") == "unsupported"

      assert Errors.classify("[twitter][error] AuthRequired: authenticated cookies needed") ==
               "needs_login"

      assert Errors.classify("[reddit][error] \"You've been blocked by network security.\"") ==
               "blocked"

      assert Errors.classify("ERROR: [youtube] x: Sign in to confirm you're not a bot") ==
               "needs_login"

      assert Errors.classify("HTTP Error 407: Proxy Authentication Required") == "address"
      assert Errors.classify("ERROR: [youtube] x: Video unavailable") == "not_found"
      assert Errors.classify("[download] File is larger than max-filesize") == "too_big"
      assert Errors.classify("something else") == "failed"
    end

    test "every code has words" do
      for code <- Errors.codes(), do: assert(is_binary(Errors.message(code, "example.com")))
    end
  end

  describe "FetchJob.file_name/3" do
    test "title and posted date, so core dates a file without its own date by its name" do
      assert FetchJob.file_name("Me at the zoo", ~N[2005-04-24 03:31:52], "/w/0-x.mp4") ==
               "Me at the zoo 2005-04-24 03.31.52.mp4"

      assert FetchJob.file_name("Me at the zoo", ~N[2005-04-24 00:00:00], "/w/0-x.MP4") ==
               "Me at the zoo 2005-04-24.mp4"
    end

    test "no title: the file's own name; characters a name cannot hold are dropped" do
      assert FetchJob.file_name(nil, nil, "/w/abc.jpg") == "abc.jpg"
      assert FetchJob.file_name("a/b: c? <d>", nil, "/w/x.png") == "a b c d.png"
      assert FetchJob.file_name("...", nil, "/w/x.png") == "fetched.png"
      assert String.length(FetchJob.file_name(String.duplicate("a", 300), nil, "/w/x.png")) == 84
    end

    test "core reads the date back from the name" do
      name = FetchJob.file_name("Me at the zoo", ~N[2005-04-24 03:31:52], "/w/x.mp4")

      assert %{taken_at_source: "filename", taken_on: ~D[2005-04-24]} =
               CaptureDate.resolve(nil, %{
                 file_type: "video",
                 original_file_name: name,
                 inserted_at: DateTime.utc_now()
               })
    end
  end

  defp after_flag(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      i -> Enum.at(args, i + 1)
    end
  end
end
