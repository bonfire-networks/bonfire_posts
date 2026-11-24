defmodule Bonfire.Posts.MediaVisibleTest do
  @moduledoc """
  Who may see a `Media`, as the `/files/redir` route checks before serving it: its creator, or whoever may see the `Media` itself (when it was published on its own) or one of the objects it's attached to.
  """
  use Bonfire.Posts.DataCase, async: false
  use Bonfire.Common.Utils

  @moduletag :backend

  alias Bonfire.Posts
  alias Bonfire.Files.Media
  alias Bonfire.Me.Fake

  setup do
    me = Fake.fake_user!()
    other = Fake.fake_user!()
    media = Bonfire.Social.Fake.upload_media(:images, me)

    {:ok, me: me, other: other, media: media}
  end

  defp attach!(me, media, boundary) do
    {:ok, post} =
      Posts.publish(
        current_user: me,
        post_attrs: %{post_content: %{html_body: "with media"}, uploaded_media: [media]},
        boundary: boundary
      )

    post
  end

  test "attached to a public post: anyone, signed in or not", %{
    me: me,
    other: other,
    media: media
  } do
    attach!(me, media, "public")

    assert Media.visible?(media, current_user: other)
    assert Media.visible?(media, current_user: nil)
  end

  test "attached to a post only its author sees: its author only", %{
    me: me,
    other: other,
    media: media
  } do
    attach!(me, media, "mentions")

    assert Media.visible?(media, current_user: me)
    refute Media.visible?(media, current_user: other)
    refute Media.visible?(media, current_user: nil)
  end

  test "attached to a private post and a public one: one visible object is enough", %{
    me: me,
    other: other,
    media: media
  } do
    attach!(me, media, "mentions")
    attach!(me, media, "public")

    assert Media.visible?(media, current_user: other)
  end

  test "published on its own: its own boundary", %{me: me, other: other} do
    public = Bonfire.Social.Fake.upload_media(:images, me, "public one")
    private = Bonfire.Social.Fake.upload_media(:images, me, "private one")

    assert {:ok, _} = Media.publish(me, public, boundary: "public")
    assert {:ok, _} = Media.publish(me, private, boundary: "mentions")

    assert Media.visible?(public, current_user: nil)
    refute Media.visible?(private, current_user: nil)
    refute Media.visible?(private, current_user: other)
  end

  test "uploaded but neither attached nor published: its creator only", %{
    me: me,
    other: other,
    media: media
  } do
    assert Media.visible?(media, current_user: me)
    refute Media.visible?(media, current_user: other)
    refute Media.visible?(media, current_user: nil)
  end
end
