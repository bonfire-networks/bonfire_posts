defmodule Bonfire.Posts.ScheduledPostsTest do
  use Bonfire.Posts.DataCase, async: true
  alias Bonfire.Posts
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake

  test "scheduled posts in the future do not appear in the feed, and ULID matches date, and scheduled post is federated at scheduled time, not immediately" do
    user = Fake.fake_user!()

    future_date =
      Date.utc_today()
      |> Date.add(7)
      |> Date.to_iso8601()

    attrs = %{
      post_content: %{
        summary: "scheduled summary",
        html_body: "<p>scheduled html</p>"
      },
      scheduled_at: future_date
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    # Check that the ULID encodes the scheduled date
    {:ok, ulid_ts} = Needle.ULID.timestamp(post.id)
    {:ok, scheduled_dt, _} = DateTime.from_iso8601(future_date <> "T00:00:00Z")
    assert ulid_ts == DateTime.to_unix(scheduled_dt, :millisecond)

    # The post should not appear in the user's feed (outbox)
    refute Bonfire.Social.FeedLoader.feed_contains?(:local, post, current_user: user)

    # nor in Posts list
    %{edges: posts} = Posts.list_by(user, skip_boundary_check: true)
    ids = Enum.map(posts, & &1.id)
    refute post.id in ids

    # cannot read it 
    assert {:error, :not_found} =
             Posts.read(post.id,
               current_user: user
             )

    # can fetch it if we really want to
    assert {:ok, _} =
             Posts.read(post.id,
               current_user: user,
               include_scheduled: true
             )

    # Check Oban jobs for federation are scheduled for the future
    # (Assumes Oban is configured to use the default repo)
    import Ecto.Query

    assert [] ==
             repo().all(
               from j in Oban.Job,
                 where:
                   (j.worker == "ActivityPub.Federator.Workers.PublisherWorker" and
                      is_nil(j.scheduled_at)) or
                     j.scheduled_at < ^DateTime.utc_now()
             )

    scheduled_jobs =
      repo().all(
        from j in Oban.Job,
          where:
            j.worker == "ActivityPub.Federator.Workers.PublisherWorker" and
              j.scheduled_at > ^DateTime.utc_now()
      )

    # There should be at least one job scheduled for the future for this user
    assert Enum.any?(scheduled_jobs, fn job ->
             Date.to_iso8601(DateTime.to_date(job.scheduled_at)) == future_date and
               job.args["user_id"] == user.id
           end)
  end
end
