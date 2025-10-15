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
    reply = %{} = List.first(replies)
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
    assert length(replies) > 0

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

  # test "debugging DB record after publishing a reply" do
  #   attrs = %{
  #     post_content: %{
  #       summary: "summary",
  #       html_body: "<p>epic html message</p>"
  #     }
  #   }

  #   user = Fake.fake_user!()

  #   assert {:ok, post} =
  #            Posts.publish(
  #              current_user: user,
  #              post_attrs: attrs,
  #              boundary: "public"
  #            )

  #   attrs_reply = %{
  #     post_content: %{
  #       summary: "summary",
  #       name: "name 2",
  #       html_body: "<p>epic html message</p>"
  #     },
  #     reply_to_id: post.id
  #   }

  #   assert {:ok, post_reply} =
  #            Posts.publish(
  #              current_user: user,
  #              post_attrs: attrs_reply,
  #              boundary: "public"
  #            )

  #   # # Debug: inspect DB record for the reply
  #   # db_reply_result =
  #   #   repo().sql("""
  #   #     SELECT id, reply_to_id, thread_id, path
  #   #     FROM bonfire_data_social_replied
  #   #     WHERE id = $1
  #   #   """, [Needle.ULID.dump!(post_reply.id)])

  #   # [db_row] = db_reply_result.rows
  #   # db_reply =
  #   #   Enum.zip(db_reply_result.columns, db_row)
  #   #   |> Map.new()

  #   # IO.inspect(db_reply, label: "DB reply record")

  #   # assert db_reply["reply_to_id"] == Needle.ULID.dump!(post.id)
  #   # assert db_reply["thread_id"] == Needle.ULID.dump!(post.id)
  # end

  test "debug Threads.find_reply_to/2 with reply_to_id" do
    user = Fake.fake_user!()

    # Create a post to reply to
    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>original post</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    # Call find_reply_to with reply_to_id
    result = Bonfire.Social.Threads.find_reply_to(%{reply_to_id: post.id}, user)
    IO.inspect(result, label: "Threads.find_reply_to result")

    # Assert it returns {:ok, reply} and reply has expected id
    assert {:ok, reply} = result
    assert reply.id == post.id
    # Optionally, check if reply has a :replied field
    # IO.inspect(reply.replied, label: "reply.replied field")
  end

  test "bonfire_data_social_replied table has expected indexes" do
    # Check if columns exist
    columns_result =
      repo().sql("""
      SELECT column_name
      FROM information_schema.columns
      WHERE table_name = 'bonfire_data_social_replied'
      """)

    column_names =
      Enum.map(columns_result.rows, fn [name] -> name end)
      |> debug("Column names on bonfire_data_social_replied")

    reply_to_exists? = "reply_to_id" in column_names
    thread_id_exists? = "thread_id" in column_names

    # Only check indexes if columns exist
    if reply_to_exists? and thread_id_exists? do
      index_result =
        repo().sql("""
        SELECT indexname
        FROM pg_indexes
        WHERE tablename = 'bonfire_data_social_replied'
        """)

      index_names =
        Enum.map(index_result.rows, fn [name] -> name end)
        |> debug("Index names on bonfire_data_social_replied")

      assert "bonfire_data_social_replied_reply_to_id_index" in index_names
      assert "bonfire_data_social_replied_thread_id_index" in index_names
    else
      flunk("""
      Missing columns in bonfire_data_social_replied:
      reply_to_id exists? #{reply_to_exists?}
      thread_id exists? #{thread_id_exists?}
      """)
    end
  end
end
