defmodule Bonfire.Posts.ThreadsPostsTest do
  use Bonfire.Posts.DataCase, async: true

  alias Bonfire.Posts
  alias Bonfire.Social.Threads
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Me.Fake

  # import ExUnit.CaptureLog

  test "reply works" do
    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    user = Fake.fake_user!()

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    attrs_reply = %{
      post_content: %{
        summary: "summary",
        name: "name 2",
        html_body: "<p>epic html message</p>"
      },
      reply_to_id: post.id
    }

    assert {:ok, post_reply} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs_reply,
               boundary: "public"
             )

    # debug(post_reply)
    assert post_reply.replied.reply_to_id == post.id
    assert post_reply.replied.thread_id == post.id
  end

  # is this desirable behaviour when there's no @ mention? prob should be configurable
  @tag :todo
  test "see a public reply to something I posted in my notifications" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()

    attrs = %{
      post_content: %{html_body: "<p>hey you have an epic html post</p>"}
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    attrs_reply = %{
      post_content: %{
        summary: "summary",
        name: "name 2",
        html_body: "<p>epic html message</p>"
      },
      reply_to_id: post.id
    }

    assert {:ok, post_reply} =
             Posts.publish(
               current_user: someone,
               post_attrs: attrs_reply,
               boundary: "public"
             )

    # me = Bonfire.Me.Users.get_current(me.id)
    assert activity =
             Bonfire.Social.FeedLoader.feed_contains?(:notifications, post_reply,
               current_user: me
             )
  end

  test "fetching a reply works" do
    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    user = Fake.fake_user!()

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    attrs_reply = %{
      post_content: %{
        summary: "summary",
        name: "name 2",
        html_body: "<p>epic html message</p>"
      },
      reply_to_id: post.id
    }

    assert {:ok, post_reply} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs_reply,
               boundary: "public"
             )

    assert {:ok, read} = Posts.read(post_reply.id, user)

    # debug(read)
    assert read.activity.replied.reply_to_id == post.id
    assert read.activity.replied.thread_id == post.id
  end

  test "can fetch a thread" do
    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    user = Fake.fake_user!()

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    attrs_reply = %{
      post_content: %{
        summary: "summary",
        name: "name 2",
        html_body: "<p>epic html message</p>"
      },
      reply_to_id: post.id
    }

    assert {:ok, post_reply} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs_reply,
               boundary: "public"
             )

    assert %{edges: replies} = Threads.list_replies(post.id, user)

    # debug(replies)
    reply = List.first(replies)
    # IO.inspect(reply)
    assert reply.reply_to_id == post.id
    assert reply.thread_id == post.id
    assert reply.path == [post.id]
  end

  test "can read nested replies of a user talking to themselves as a guest" do
    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    user = Fake.fake_user!()

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    attrs_reply = %{
      post_content: %{
        summary: "summary",
        name: "name 2",
        html_body: "<p>epic html message</p>"
      },
      reply_to_id: post.id
    }

    assert {:ok, post_reply} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs_reply,
               boundary: "public"
             )

    # debug(post_reply, "first reply")

    attrs_reply3 = %{
      post_content: %{
        summary: "summary",
        name: "name 3",
        html_body: "<p>epic html message</p>"
      },
      reply_to_id: post_reply.id
    }

    assert {:ok, post_reply3} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs_reply3,
               boundary: "public"
             )

    # debug(post_reply3, "nested reply")

    assert %{edges: replies} = Threads.list_replies(post.id, user)

    # debug(replies)
    assert length(replies) == 2
    reply = List.last(replies)
    reply3 = List.first(replies)

    assert reply.reply_to_id == post.id
    assert reply.thread_id == post.id
    assert reply.path == [post.id]

    assert reply3.reply_to_id == post_reply.id
    assert reply3.thread_id == post.id
    assert reply3.path == [post.id, post_reply.id]
  end

  # Forking is not yet fully worked out.
  # test "can get nested replies across a fork" do
  #   attrs = %{post_content: %{summary: "summary", html_body: "<p>epic html message</p>"}}
  #   user = Fake.fake_user!()
  #   assert {:ok, post} = Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

  #   attrs_reply = %{post_content: %{summary: "summary", html_body: "<p>epic html message</p>"}, reply_to_id: post.id}
  #   assert {:ok, post_reply} = Posts.publish(current_user: user, post_attrs: attrs_reply, boundary: "public")

  #   attrs_reply3 = %{post_content: %{summary: "summary", html_body: "<p>epic html message</p>"}, reply_to_id: post_reply.id, thread_id: post_reply.id}
  #   assert {:ok, post_reply3} = Posts.publish(current_user: user, post_attrs: attrs_reply3, boundary: "public")

  #   assert %{edges: replies} = Threads.list_replies(post.id, user)

  #   # debug(replies)
  #   assert length(replies) == 2
  #   reply = List.last(replies)
  #   reply3 = List.first(replies)

  #   assert reply.activity.replied.reply_to_id == post.id
  #   assert reply.activity.replied.thread_id == post.id
  #   assert reply.activity.replied.path == [post.id]

  #   assert reply3.activity.replied.reply_to_id == post_reply.id
  #   assert reply3.activity.replied.thread_id == post_reply.id
  #   assert reply3.activity.replied.path == [post.id, post_reply.id]
  # end

  test "can arrange nested replies into a tree" do
    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    user = Fake.fake_user!()

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    attrs_reply = %{
      post_content: %{
        summary: "summary",
        name: "name 2",
        html_body: "<p>epic html message</p>"
      },
      reply_to_id: post.id
    }

    assert {:ok, post_reply} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs_reply,
               boundary: "public"
             )

    attrs_reply3 = %{
      post_content: %{
        summary: "summary",
        name: "name 3",
        html_body: "<p>epic html message</p>"
      },
      reply_to_id: post_reply.id
    }

    assert {:ok, post_reply3} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs_reply3,
               boundary: "public"
             )

    assert %{edges: replies} = Threads.list_replies(post.id, user)

    threaded_replies = Bonfire.Social.Threads.prepare_replies_tree(replies, current_user: user)

    debug(threaded_replies, "threaded_replies_tree")

    assert [
             {
               %{} = reply,
               [
                 {
                   %{} = reply3,
                   []
                 }
               ]
             }
           ] = threaded_replies

    assert reply.reply_to_id == post.id
    assert reply.thread_id == post.id
    assert reply.path == [post.id]

    assert reply3.reply_to_id == post_reply.id
    assert reply3.thread_id == post.id
    assert reply3.path == [post.id, post_reply.id]
  end
end
