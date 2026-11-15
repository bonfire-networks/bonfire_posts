# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Posts.PostMediaDeleteTest do
  @moduledoc """
  A Media row is shared by everything that points at its URL. Deleting a post deletes the media it attached only when nothing else references that row (another object's attachment, or a user's alias).
  """
  use Bonfire.Posts.DataCase, async: false
  use Bonfire.Common.Utils
  @moduletag :backend

  alias Bonfire.Posts
  alias Bonfire.Files.Media
  alias Bonfire.Social.Graph.Aliases
  alias Bonfire.Me.Fake

  defp publish_with_media(user, url) do
    {:ok, post} =
      Posts.publish(
        current_user: user,
        boundary: "public",
        post_attrs: %{
          post_content: %{name: "With link", html_body: "body"},
          uploaded_media: [%{"href" => url}]
        }
      )

    post
  end

  defp url, do: "https://example.com/shared-media-#{System.unique_integer([:positive])}.jpg"

  test "deleting a post deletes the media nothing else references (control)" do
    a = Fake.fake_user!()
    url = url()
    post = publish_with_media(a, url)
    assert {:ok, _} = Media.get_by_path(url)

    assert {:ok, _} = Posts.delete(post, current_user: a)

    assert {:error, :not_found} = Media.get_by_path(url)
  end

  test "deleting a post keeps a media another user has as their avatar" do
    import Ecto.Query
    a = Fake.fake_user!()
    b = Fake.fake_user!()
    url = url()
    post = publish_with_media(a, url)
    assert {:ok, media} = Media.get_by_path(url)

    {1, _} =
      repo().update_all(
        from(p in Bonfire.Data.Social.Profile, where: p.id == ^b.id),
        set: [icon_id: media.id]
      )

    assert {:ok, _} = Posts.delete(post, current_user: a)

    assert {:ok, _} = Media.get_by_path(url)
    assert %{icon_id: icon_id} = repo().get(Bonfire.Data.Social.Profile, b.id)
    assert icon_id == media.id
  end

  test "deleting a post keeps a media another user aliased, and their alias" do
    a = Fake.fake_user!()
    b = Fake.fake_user!()
    url = url()
    post = publish_with_media(a, url)
    assert {:ok, media} = Media.get_by_path(url)

    assert {:ok, _} =
             Aliases.add(b, {:provider, :orcid, "ORCID", url, %{"sub" => "someone"}})

    assert Aliases.exists?(b, media)

    assert {:ok, _} = Posts.delete(post, current_user: a)

    assert {:ok, _} = Media.get_by_path(url)
    assert Aliases.exists?(b, media)
  end
end
