defmodule Bonfire.Posts.API.MastoAdapter do
  @moduledoc "Mastodon API adapter for post creation"

  import Untangle
  use Bonfire.Common.Repo
  use Bonfire.Common.Utils

  alias Bonfire.API.GraphQL.RestAdapter
  alias Bonfire.API.MastoCompat.Mappers

  @doc "Create a new status (POST /api/v1/statuses)"
  def create_status(params, conn) do
    current_user = conn.assigns[:current_user]

    if is_nil(current_user) do
      RestAdapter.error_fn({:error, :unauthorized}, conn)
    else
      try do
        case publish_from_masto_params(params, current_user) do
          {:ok, post} ->
            post =
              post
              |> repo().maybe_preload([
                :post_content,
                :media,
                :replied,
                activity: [:subject]
              ])

            status = Mappers.Status.from_post(post, current_user: current_user)
            RestAdapter.json(conn, status)

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

  defp publish_from_masto_params(params, current_user) do
    with {:ok, post_attrs} <- build_post_attrs(params, current_user),
         {boundary, extra_circles} <- visibility_to_boundary(params["visibility"]),
         opts <- build_publish_opts(params, current_user, boundary, extra_circles, post_attrs),
         {:ok, post} <- Bonfire.Posts.publish(opts) do
      {:ok, post}
    end
  end

  defp build_post_attrs(params, current_user) do
    status_text = params["status"] || ""

    with {:ok, media} <-
           fetch_media_by_ids(params["media_ids"] || params["media_ids[]"] || [], current_user) do
      if status_text == "" and media == [] do
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

  defp build_publish_opts(params, current_user, boundary, extra_circles, post_attrs) do
    [
      current_user: current_user,
      post_attrs: post_attrs,
      boundary: boundary,
      to_circles: extra_circles
    ]
    |> maybe_add_sensitive(params["sensitive"])
  end

  defp visibility_to_boundary("public"), do: {"public", []}
  defp visibility_to_boundary("unlisted"), do: {"unlisted", []}
  defp visibility_to_boundary("private"), do: {"mentions", [{:followers, nil}]}
  defp visibility_to_boundary("direct"), do: {"mentions", []}
  defp visibility_to_boundary(_), do: {"public", []}

  defp maybe_add_sensitive(opts, sensitive) when sensitive in [true, "true", "1"] do
    Keyword.put(opts, :sensitive, true)
  end

  defp maybe_add_sensitive(opts, _), do: opts
end
