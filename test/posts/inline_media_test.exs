defmodule Bonfire.Posts.InlineMediaTest do
  @moduledoc """
  Media an author places in a post's body (an image, or a player's link, alone in its paragraph) is attached to the post as usual. Its URL has to reach the stored body as written, so the body can still be matched with its media (see `Bonfire.Files.InlineMedia`), to leave it out of the attachment list and render it where it sits.
  """
  use Bonfire.Posts.DataCase, async: false
  use Bonfire.Common.Utils

  @moduletag :backend

  alias Bonfire.Posts
  alias Bonfire.Files.InlineMedia
  alias Bonfire.Social.PostContents
  alias Bonfire.Me.Fake

  setup do
    # link previews find nothing: these tests are about the body, not unfurling
    Tesla.Mock.mock(fn _ -> %Tesla.Env{status: 404, body: ""} end)

    me = Fake.fake_user!()
    inline = Bonfire.Social.Fake.upload_media(:images, me, "inline")
    other = Bonfire.Social.Fake.upload_media(:images, me, "other")

    {:ok, me: me, inline: inline, other: other}
  end

  defp publish!(me, body, media) do
    {:ok, post} =
      Posts.publish(
        current_user: me,
        post_attrs: %{post_content: %{html_body: body}, uploaded_media: media},
        boundary: "public"
      )

    post
  end

  defp stored_body(post) do
    Bonfire.Common.Needles.get!(id(post), skip_boundary_check: true)
    |> repo().maybe_preload(:post_content, force: true)
    |> e(:post_content, :html_body, nil)
  end

  test "an image alone in its paragraph is stored as written, and still matches its media", %{
    me: me,
    inline: inline,
    other: other
  } do
    url = Bonfire.Files.inline_url(inline)
    post = publish!(me, "Intro\n\n![](#{url})\n\nmore", [inline, other])

    assert stored_body(post) =~ "![](#{url})"
    assert InlineMedia.inline_ids(stored_body(post), [inline, other]) == [id(inline)]
  end

  test "a bare URL alone in its paragraph still matches its media", %{me: me, inline: inline} do
    post = publish!(me, "Intro\n\n#{Bonfire.Files.inline_url(inline)}\n\nmore", [inline])

    assert InlineMedia.inline_ids(stored_body(post), [inline]) == [id(inline)]
  end

  test "an image in the middle of a sentence still matches, so it shows once", %{
    me: me,
    inline: inline
  } do
    post = publish!(me, "see ![](#{Bonfire.Files.inline_url(inline)}) here", [inline])

    assert InlineMedia.inline_ids(stored_body(post), [inline]) == [id(inline)]
  end

  test "a link in the middle of a sentence doesn't place its media", %{me: me, inline: inline} do
    post = publish!(me, "see #{Bonfire.Files.inline_url(inline)} here", [inline])

    assert InlineMedia.inline_ids(stored_body(post), [inline]) == []
  end

  test "control: a body without the URL places nothing", %{me: me, inline: inline, other: other} do
    post = publish!(me, "no media in the text", [inline, other])

    assert InlineMedia.inline_ids(stored_body(post), [inline, other]) == []
  end

  test "after an edit, the new body is what places media", %{me: me, inline: inline} do
    url = Bonfire.Files.inline_url(inline)
    post = publish!(me, "Intro\n\n![](#{url})", [inline])
    assert InlineMedia.inline_ids(stored_body(post), [inline]) == [id(inline)]

    assert {:ok, _} = PostContents.edit(me, id(post), %{html_body: "no image now"})
    assert InlineMedia.inline_ids(stored_body(post), [inline]) == []

    assert {:ok, _} = PostContents.edit(me, id(post), %{html_body: "back\n\n![](#{url})"})
    assert InlineMedia.inline_ids(stored_body(post), [inline]) == [id(inline)]
  end

  # one pass over an object's media and body: which media the body places (where it's cut, or an image it shows), the cut parts to render, and the rest for the attachment list
  describe "split/3" do
    defp placed_ids(%{inline_media: inline_media}),
      do: inline_media |> Map.values() |> Enum.map(&id/1) |> Enum.uniq()

    test "a markdown body: an image alone in its paragraph is placed and cut there, the rest is listed",
         %{inline: inline, other: other} do
      url = Bonfire.Files.inline_url(inline)
      split = InlineMedia.split([inline, other], "Intro\n\n![](#{url})\n\nmore")

      assert placed_ids(split) == [id(inline)]
      assert Enum.map(split.unplaced, &id/1) == [id(other)]
      assert {:url, url} in split.parts
    end

    test "a markdown body: an image in the middle of a sentence is placed, so it shows once",
         %{inline: inline} do
      split = InlineMedia.split([inline], "see ![](#{Bonfire.Files.inline_url(inline)}) here")

      assert placed_ids(split) == [id(inline)]
      assert split.unplaced == []
    end

    # it isn't cut, so it shows only as a link in the text: its card stays in the list
    test "a markdown body: a link in the middle of a sentence isn't placed, so it keeps its card",
         %{inline: inline} do
      split = InlineMedia.split([inline], "see #{Bonfire.Files.inline_url(inline)} here")

      assert placed_ids(split) == []
      assert Enum.map(split.unplaced, &id/1) == [id(inline)]
    end

    test "an HTML body: a link alone in its paragraph is placed and cut there, one in a sentence isn't",
         %{inline: inline, other: other} do
      url = Bonfire.Files.inline_url(inline)
      other_url = Bonfire.Files.inline_url(other)

      split =
        InlineMedia.split(
          [inline, other],
          ~s(<p>a</p><p><a href="#{url}">#{url}</a></p><p>see <a href="#{other_url}">it</a> here</p>)
        )

      assert placed_ids(split) == [id(inline)]
      assert Enum.map(split.unplaced, &id/1) == [id(other)]
      assert {:url, url} in split.parts
    end

    test "control: a body without any of the URLs places nothing and isn't cut",
         %{inline: inline, other: other} do
      split = InlineMedia.split([inline, other], "no media in the text")

      assert split.inline_media == %{}
      assert split.parts == nil
      assert Enum.map(split.unplaced, &id/1) == [id(inline), id(other)]
    end
  end

  # the composer writes `upload:<ref>` for a file not uploaded yet: at publish each becomes the stored media's URL
  describe "swap_upload_refs/2" do
    test "puts each stored media's URL in place of its upload ref", %{
      inline: inline,
      other: other
    } do
      body = "Intro\n\n![](upload:phx-1)\n\nmid ![](upload:phx-2) end"

      swapped =
        InlineMedia.swap_upload_refs(body, %{"phx-1" => inline, "phx-2" => other})

      assert swapped ==
               "Intro\n\n![](#{Bonfire.Files.inline_url(inline)})\n\nmid ![](#{Bonfire.Files.inline_url(other)}) end"
    end

    test "drops the image of a ref with no stored media (removed before publishing)", %{
      inline: inline
    } do
      body = "Intro\n\n![](upload:phx-1)\n\n![](upload:phx-gone)\n\nmore"

      assert InlineMedia.swap_upload_refs(body, %{"phx-1" => inline}) ==
               "Intro\n\n![](#{Bonfire.Files.inline_url(inline)})\n\n\n\nmore"
    end

    test "leaves a body without refs as it is" do
      assert InlineMedia.swap_upload_refs("no refs here", %{}) == "no refs here"
      assert InlineMedia.swap_upload_refs(nil, %{}) == nil
    end
  end

  # a URL ending a line is stored in its own paragraph, so the post federates with it alone on its line, where another instance (which gets HTML) places its media
  describe "a URL ending a line gets its own paragraph" do
    @player "https://video.example.com/w/x"

    # what another instance would cut, from the HTML it gets
    defp placed_elsewhere?(body, url) do
      {:url, url} in Bonfire.Common.Text.markdown_parts(
        Bonfire.Common.Text.maybe_markdown_to_html(body, []),
        MapSet.new([url]),
        []
      )
    end

    for {name, body} <- [
          {"after its label", "Intro\n\nWatch: #{@player}\n\nmore"},
          {"ending a paragraph", "Intro\n\nsee this #{@player}\n\nmore"},
          {"on a line of a longer paragraph", "Intro\n#{@player}\nmore"}
        ] do
      test "when published, #{name}", %{me: me} do
        post = publish!(me, unquote(body), [])

        assert placed_elsewhere?(stored_body(post), @player), stored_body(post)
      end
    end

    test "when edited", %{me: me} do
      post = publish!(me, "Intro", [])

      assert {:ok, _} = PostContents.edit(me, id(post), %{html_body: "Watch: #{@player}"})

      # an edit isn't linkified (unlike publishing), so this checks the paragraph the URL is stored in
      assert stored_body(post) =~ ~r/^Watch:\s*\n\n#{Regex.escape(@player)}$/
    end

    # the control: a URL already alone in its paragraph is placed elsewhere as stored, and one in a sentence stays where it is
    test "a URL already alone is stored as written, one in a sentence stays in it", %{me: me} do
      alone = publish!(me, "Intro\n\n#{@player}\n\nmore", [])
      assert placed_elsewhere?(stored_body(alone), @player)

      in_sentence = publish!(me, "see #{@player} there", [])
      refute placed_elsewhere?(stored_body(in_sentence), @player)
      assert stored_body(in_sentence) =~ "see "
      refute stored_body(in_sentence) =~ "\n\n"
    end
  end

  # Linkify turns a bare URL into `[display](href)` at ingest: the href must stay the URL as written, or it no longer matches its media
  describe "Linkify keeps a player's URL alone on its line as written" do
    for url <- [
          "https://video.example.com/@user/123",
          "https://www.youtube.com/watch?v=x#t=30",
          "https://en.wikipedia.org/wiki/Foo_(bar)",
          "https://www.youtube-nocookie.com/embed/x"
        ] do
      test url, %{me: me} do
        post = publish!(me, "Intro\n\n#{unquote(url)}\n\nmore", [])

        assert Bonfire.Common.Text.standalone_urls(stored_body(post)) == [unquote(url)]
      end
    end
  end
end
