defmodule Bonfire.Posts.API.MastoAdapter do
  @moduledoc "Mastodon API adapter for post creation"

  import Untangle
  use Bonfire.Common.Repo
  use Bonfire.Common.Utils

  alias Bonfire.API.GraphQL.RestAdapter

  @doc "Create a new status (POST /api/v1/statuses)"
  def create_status(params, conn) do
    current_user = conn.assigns[:current_user]

    if is_nil(current_user) do
      RestAdapter.error_fn({:error, :unauthorized}, conn)
    else
      try do
        case publish_from_masto_params(params, current_user) do
          # Mastodon answers a ScheduledStatus, not a Status, for a post to be published later (B49 decision 1)
          {:scheduled, post, scheduled} ->
            RestAdapter.json(conn, scheduled_status(post, scheduled, params))

          {:ok, post} ->
            # read back through GraphQL, as show does
            case read_back(id(post), current_user) do
              {:ok, status} ->
                RestAdapter.json(conn, status)

              # the post exists by now, so an error here makes the client post it again
              {:error, reason} ->
                warn(
                  reason,
                  "Published status #{id(post)} could not be read back, answering from the published activity"
                )

                case published_status(post, current_user) do
                  %{} = status -> RestAdapter.json(conn, status)
                  _ -> RestAdapter.error_fn({:error, reason}, conn)
                end
            end

          {:error, reason} ->
            error(reason, "Failed to create status")
            RestAdapter.error_fn({:error, reason}, conn)
        end
      rescue
        e ->
          error(e, "Failed to create status")
          RestAdapter.error_fn({:error, e}, conn)
      end
    end
  end

  # a raise here (a DB timeout) also reaches the fallback, not the `rescue` that answers an error
  defp read_back(post_id, current_user) do
    Bonfire.Social.API.GraphQLMasto.Adapter.read_status(post_id, current_user)
  rescue
    e -> {:error, e}
  end

  # the activity publish gave back, run through GraphQL as its root (as streaming does), skipping the `status(id:)` lookup
  defp published_status(%{activity: %{id: _} = activity} = post, current_user)
       when is_struct(post) do
    Bonfire.Social.API.GraphQLMasto.Adapter.published_status(
      Map.put(activity, :object, post),
      current_user
    )
  end

  # a poll comes back from the `createPoll` mutation as a map, so its question is read back for the activity
  defp published_status(poll, current_user) do
    with id when is_binary(id) <- id(poll),
         {:ok, question} <- Bonfire.Poll.Questions.read(id, current_user: current_user),
         true <- is_struct(question) do
      published_status(question, current_user)
    else
      _ -> nil
    end
  end

  # everything that can refuse the request is checked before anything is published
  defp publish_from_masto_params(params, current_user) do
    with {:ok, scheduled_at} <- validate_scheduled_at(params),
         {:ok, visibility} <- validate_visibility(params["visibility"]),
         {:ok, post_attrs} <- build_post_attrs(params, current_user),
         post_attrs = maybe_put_scheduled_at(post_attrs, scheduled_at),
         {:ok, opts} <- build_publish_opts(params, visibility, current_user, post_attrs),
         {:ok, post} <- publish_status(params, opts) do
      if scheduled_at do
        {:scheduled, post,
         %{
           scheduled_at: scheduled_at,
           visibility:
             visibility || Bonfire.API.MastoCompat.Helpers.default_visibility(current_user),
           media_ids: Enum.map(post_attrs[:uploaded_media] || [], &id/1)
         }}
      else
        {:ok, post}
      end
    end
  end

  # Mastodon refuses a schedule less than 5 minutes ahead (B49 decision 2)
  @min_schedule_seconds 5 * 60

  defp validate_scheduled_at(%{"scheduled_at" => at} = params) when is_binary(at) and at != "" do
    case parse_scheduled_at(at) do
      {:ok, dt} ->
        cond do
          DateTime.diff(dt, DateTime.utc_now(), :second) < @min_schedule_seconds ->
            {:error,
             {:unprocessable_entity, "Scheduled at must be at least 5 minutes in the future"}}

          # polls are created by their own extension, which does not schedule; publishing one at once would ignore the request
          is_map(params["poll"]) ->
            {:error, {:unprocessable_entity, "Scheduling a poll is not supported"}}

          true ->
            {:ok, DateTime.truncate(dt, :second)}
        end

      _ ->
        {:error, {:unprocessable_entity, "Scheduled at is not a valid date"}}
    end
  end

  defp validate_scheduled_at(%{"scheduled_at" => at}) when at not in [nil, ""],
    do: {:error, {:unprocessable_entity, "Scheduled at is not a valid date"}}

  defp validate_scheduled_at(_params), do: {:ok, nil}

  # a value without an offset is read as UTC, as `Posts.publish` reads it (`scheduled_date_time/1` in `posts.publish.ex`)
  defp parse_scheduled_at(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        case NaiveDateTime.from_iso8601(at) do
          {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
          _ -> :error
        end
    end
  end

  defp maybe_put_scheduled_at(post_attrs, nil), do: post_attrs

  defp maybe_put_scheduled_at(post_attrs, %DateTime{} = scheduled_at),
    do: Map.put(post_attrs, :scheduled_at, scheduled_at)

  @visibilities ["public", "unlisted", "private", "direct"]

  # an unknown visibility is refused rather than guessed (B49 decision 4); omitted means the user's default
  defp validate_visibility(nil), do: {:ok, nil}
  defp validate_visibility(""), do: {:ok, nil}
  defp validate_visibility(visibility) when visibility in @visibilities, do: {:ok, visibility}

  defp validate_visibility(_),
    do: {:error, {:unprocessable_entity, "Visibility is not included in the list"}}

  # the Mastodon ScheduledStatus entity: the post's id (a ULID dated at the schedule) and the params it was posted with
  defp scheduled_status(post, scheduled, params) do
    %{
      "id" => id(post),
      "scheduled_at" => DateTime.to_iso8601(scheduled.scheduled_at),
      "params" => %{
        "text" => params["status"],
        "visibility" => scheduled.visibility,
        "spoiler_text" => params["spoiler_text"],
        "sensitive" => params["sensitive"] in [true, "true", "1"],
        "in_reply_to_id" => params["in_reply_to_id"],
        "media_ids" => scheduled.media_ids,
        "poll" => nil,
        "language" => params["language"],
        "scheduled_at" => nil,
        "idempotency" => nil,
        "application_id" => nil,
        "with_rate_limit" => false
      },
      "media_attachments" => []
    }
  end

  defp publish_status(%{"poll" => %{} = poll}, opts) do
    if Extend.module_enabled?(Bonfire.Poll.API.GraphQLMasto.Adapter, opts) do
      Bonfire.Poll.API.GraphQLMasto.Adapter.create_poll(poll, boundary_list_as_to_boundaries(opts))
    else
      {:error, {:unprocessable_entity, "Polls are not available"}}
    end
  end

  defp publish_status(_params, opts), do: Bonfire.Posts.publish(opts)

  # the `createPoll` mutation takes `boundary` as one string, and a list as `toBoundaries`
  defp boundary_list_as_to_boundaries(opts) do
    case opts[:boundary] do
      boundaries when is_list(boundaries) ->
        opts |> Keyword.delete(:boundary) |> Keyword.put(:to_boundaries, boundaries)

      _ ->
        opts
    end
  end

  defp build_post_attrs(params, current_user) do
    status_text = params["status"] || ""

    with {:ok, media} <-
           fetch_media_by_ids(params["media_ids"] || params["media_ids[]"] || [], current_user) do
      if status_text == "" and media == [] and not is_map(params["poll"]) do
        {:error, {:unprocessable_entity, "Text can't be blank"}}
      else
        {:ok,
         %{
           post_content: %{
             html_body: status_text,
             summary: params["spoiler_text"]
           },
           reply_to_id: params["in_reply_to_id"],
           uploaded_media: media
         }}
      end
    end
  end

  defp fetch_media_by_ids(nil, _current_user), do: {:ok, []}
  defp fetch_media_by_ids([], _current_user), do: {:ok, []}

  defp fetch_media_by_ids(media_ids, current_user) when is_list(media_ids) do
    media_ids
    |> Enum.reduce_while({:ok, []}, fn media_id, {:ok, media} ->
      case fetch_owned_media(media_id, current_user) do
        {:ok, item} -> {:cont, {:ok, [item | media]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, media} -> {:ok, Enum.reverse(media)}
      error -> error
    end
  end

  defp fetch_media_by_ids(media_id, current_user) when is_binary(media_id) do
    fetch_media_by_ids([media_id], current_user)
  end

  defp fetch_media_by_ids(media_ids, current_user) when is_map(media_ids) do
    media_ids
    |> Enum.sort_by(fn {index, _id} -> index end)
    |> Enum.map(fn {_index, media_id} -> media_id end)
    |> fetch_media_by_ids(current_user)
  end

  defp fetch_media_by_ids(_other, _current_user), do: {:ok, []}

  defp fetch_owned_media(media_id, current_user) when is_binary(media_id) and media_id != "" do
    current_user_id = id(current_user)

    with {:ok, media} <- Bonfire.Files.Media.one(id: media_id),
         true <- media.creator_id == current_user_id do
      {:ok, media}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_owned_media(_media_id, _current_user), do: {:error, :not_found}

  defp build_publish_opts(params, visibility, current_user, post_attrs) do
    context_id = params["context_id"]

    base_opts =
      [current_user: current_user, post_attrs: post_attrs]
      |> maybe_add_sensitive(params["sensitive"])
      |> maybe_add_context_id(context_id)

    cond do
      context_id && is_nil(visibility) ->
        apply_context_boundary(base_opts, context_id)

      # a group that cannot be loaded is refused whatever the visibility (B49 decision 6)
      context_id ->
        with {:ok, _context} <- load_context(context_id, base_opts) do
          explicit_boundary_opts(base_opts, visibility, context_id, current_user)
        end

      # omitted: the user's default preset, as the web composer opens with (B49 decision 3), passed as a list in `boundary` as the composer does (`PostsLiveHandler`)
      is_nil(visibility) ->
        {:ok, Keyword.put(base_opts, :boundary, default_boundary_ids(current_user))}

      true ->
        explicit_boundary_opts(base_opts, visibility, context_id, current_user)
    end
  end

  defp explicit_boundary_opts(base_opts, visibility, context_id, current_user) do
    {boundary, extra_circles} = visibility_to_boundary(visibility, current_user)
    extra_circles = if context_id, do: [context_id | extra_circles], else: extra_circles

    {:ok,
     base_opts
     |> Keyword.put(:boundary, boundary)
     |> Keyword.put(:to_circles, extra_circles)}
  end

  # a group that cannot be loaded is refused, never posted with some other audience (B49 decision 6)
  defp apply_context_boundary(opts, context_id) do
    with {:ok, context} <- load_context(context_id, opts) do
      dcv = Bonfire.Classify.Boundaries.read_default_content_visibility(context)

      # no `to_circles`: that gave each post an ACL of its own; the group's shared ACLs are attached by `SetBoundaries` wherever the post comes from
      # circles = Bonfire.Classify.Boundaries.post_circles_for_group(context)
      boundaries = dcv |> List.wrap() |> Enum.reject(&is_nil/1)
      boundaries = if boundaries == [], do: ["public"], else: boundaries

      {:ok, Keyword.put(opts, :to_boundaries, boundaries)}
    end
  end

  defp load_context(context_id, opts) do
    with true <-
           Extend.module_enabled?(Bonfire.Classify.Boundaries, opts) and
             Extend.module_enabled?(Bonfire.Classify.Categories, opts),
         {:ok, context} <- Bonfire.Classify.Categories.get(context_id, opts) do
      {:ok, context}
    else
      _ -> {:error, {:unprocessable_entity, "Group not found"}}
    end
  end

  defp maybe_add_context_id(opts, nil), do: opts
  defp maybe_add_context_id(opts, context_id), do: Keyword.put(opts, :context_id, context_id)

  defp visibility_to_boundary("public", _current_user), do: {"public", []}
  defp visibility_to_boundary("unlisted", _current_user), do: {"unlisted", []}

  defp visibility_to_boundary("private", current_user) do
    followers = Bonfire.Boundaries.Circles.get_stereotype_circle_ids(current_user, :followers)
    {"mentions", followers}
  end

  defp visibility_to_boundary("direct", _current_user), do: {"mentions", []}

  # the preset slugs or, for a custom preset, the ACL id
  defp default_boundary_ids(current_user) do
    Bonfire.Boundaries.Presets.default_boundaries(current_user: current_user)
    |> List.wrap()
    |> Enum.map(fn
      {id, _name} -> to_string(id)
      id -> to_string(id)
    end)
  end

  defp maybe_add_sensitive(opts, sensitive) when sensitive in [true, "true", "1"] do
    Keyword.put(opts, :sensitive, true)
  end

  defp maybe_add_sensitive(opts, _), do: opts
end
