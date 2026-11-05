defmodule Bonfire.Posts.PostEditVersioningTest do
  use Bonfire.Posts.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Posts
  alias Bonfire.Social.PostContents

  alias Bonfire.Me.Fake

  test "versioning is enabled (PaperTrail is available)" do
    assert PostContents.versioning_enabled?([])
  end

  test "editing a post records versions attributed to the editor" do
    user = Fake.fake_user!()

    post =
      fake_post!(user, "public", %{
        post_content: %{
          name: "original title",
          html_body: "original body"
        }
      })

    assert {:ok, updated} =
             PostContents.edit(user, post.id, %{
               html_body: "updated body"
             })

    assert updated.html_body =~ "updated body"

    versions = PostContents.get_versions(updated, current_user: user)

    # v1 is created retroactively on first edit, v2 is the edit itself
    assert [v1, v2] = versions

    assert v1.previous_version == %{}
    assert ed(v1.current_version, :html_body, nil) =~ "original body"

    assert ed(v2.current_version, :html_body, nil) =~ "updated body"
    assert ed(v2.previous_version, :html_body, nil) =~ "original body"
    assert id(v2.editor) == id(user)
  end

  test "get_versions_diffed computes a diff between versions" do
    user = Fake.fake_user!()

    post =
      fake_post!(user, "public", %{
        post_content: %{html_body: "some original text"}
      })

    assert {:ok, updated} =
             PostContents.edit(user, post.id, %{
               html_body: "some edited text"
             })

    assert [_v1, v2] = PostContents.get_versions_diffed(updated, current_user: user)

    assert v2.diff_count > 0
  end

  # "clone_context" is what the reply composer sends by default: the reply gets the audience of the post it replies to. "public" is a chosen audience.
  for boundary <- ["clone_context", "public"] do
    test "the author of a reply with the boundary #{boundary} can edit it" do
      op = Fake.fake_user!()
      replier = Fake.fake_user!()
      post = fake_post!(op, "public", %{post_content: %{html_body: "the opening post"}})

      assert {:ok, reply} =
               Posts.publish(
                 current_user: replier,
                 post_attrs: %{post_content: %{html_body: "the reply"}, reply_to_id: post.id},
                 boundary: unquote(boundary)
               )

      assert {:ok, updated} =
               PostContents.edit(replier, reply.id, %{html_body: "the reply, edited"})

      assert updated.html_body =~ "the reply, edited"
    end
  end
end
