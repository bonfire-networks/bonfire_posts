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
    with {:ok, post_attrs} <- build_post_attrs(params),
         boundary <- visibility_to_boundary(params["visibility"]),
         opts <- build_publish_opts(params, current_user, boundary, post_attrs),
         {:ok, post} <- Bonfire.Posts.publish(opts) do
      {:ok, post}
    end
  end

  defp build_post_attrs(params) do
    media = fetch_media_by_ids(params["media_ids"] || params["media_ids[]"] || [])
    status_text = params["status"] || ""

    if status_text == "" and media == [] do
      {:error, "Validation failed: Text can't be blank"}
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

  defp build_publish_opts(params, current_user, boundary, post_attrs) do
    [
      current_user: current_user,
      post_attrs: post_attrs,
      boundary: boundary
    ]
    |> maybe_add_sensitive(params["sensitive"])
  end

  defp visibility_to_boundary("public"), do: "public"

  defp visibility_to_boundary("unlisted") do
    debug("unlisted visibility not yet implemented, treating as public")
    "public"
  end

  defp visibility_to_boundary("private"), do: "followers"
  defp visibility_to_boundary("direct"), do: "mentions"
  defp visibility_to_boundary(_), do: "public"

  defp fetch_media_by_ids(nil), do: []
  defp fetch_media_by_ids([]), do: []

  defp fetch_media_by_ids(media_ids) when is_list(media_ids) do
    media_ids
    |> Enum.map(fn id ->
      case Bonfire.Files.Media.one(id: id) do
        {:ok, media} -> media
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_media_by_ids(media_id) when is_binary(media_id) do
    fetch_media_by_ids([media_id])
  end

  defp fetch_media_by_ids(media_ids) when is_map(media_ids) do
    fetch_media_by_ids(Map.values(media_ids))
  end

  defp fetch_media_by_ids(_other), do: []

  defp maybe_add_sensitive(opts, sensitive) when sensitive in [true, "true", "1"] do
    Keyword.put(opts, :sensitive, true)
  end

  defp maybe_add_sensitive(opts, _), do: opts
end
