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
