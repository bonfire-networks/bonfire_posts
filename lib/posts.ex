defmodule Bonfire.Posts do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  use Arrows
  import Untangle
  use Bonfire.Common.E
  import Bonfire.Boundaries.Queries
  alias Bonfire.Data.Social.Post
  # alias Bonfire.Data.Social.Replied
  # alias Bonfire.Data.Social.Activity

  # alias Bonfire.Boundaries.Circles
  # alias Bonfire.Boundaries.Verbs

  alias Bonfire.Social.Activities
  # alias Bonfire.Social.FeedActivities
  # alias Bonfire.Social.Feeds
  alias Bonfire.Social.Objects
  alias Bonfire.Social
  # alias Bonfire.Social.PostContents
  alias Bonfire.Social.Tags
  alias Bonfire.Social.Threads

  # alias Ecto.Changeset

  use Bonfire.Common.Repo,
    schema: Post,
    searchable_fields: [:id],
    sortable_fields: [:id]

  use Bonfire.Common.Utils

  # import Bonfire.Boundaries.Queries

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Post
  def query_module, do: __MODULE__

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      "Note",
      {"Create", "Note"},
      # {"Update", "Note"},
      {"Create", "Article"}
      # {"Update", "Article"}
    ]

  @doc """
  TODO: Creates a draft post. Not implemented yet.

  ## Parameters

  - `creator`: The creator of the draft post.
  - `attrs`: Attributes for the draft post.
  """
  def draft(_creator, _attrs) do
    # TODO: create as private
    # with {:ok, post} <- create(creator, attrs) do
    #   {:ok, post}
    # end
    {:error, :not_implemented}
  end

  @doc """
  Publishes a post.

  ## Parameters

  - `opts`: Options for publishing the post.

  ## Returns

  `{:ok, post}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Posts.publish(
        current_user: me, 
        boundary: "public",
        post_attrs: %{
          post_content: %{
            name: "test post title",
            html_body: "<p>epic html message</p>"
          }
        })
      {:ok, %Post{}}
  """
  def publish(opts) do
    run_epic(:publish, to_options(opts))
    # |> debug("published")
  end

  @doc """
  Deletes a post.

  Note: You should use `Bonfire.Social.Objects.delete/2` instead.

  ## Parameters

  - `object`: The post object to delete.
  - `opts`: Options for deleting the post.

  ## Returns

  `{:ok, deleted_post}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Posts.delete(post)
      {:ok, %Post{}}
  """
  def delete(object, opts \\ []) do
    opts =
      to_options(opts)
      |> Keyword.put(:object, object)

    # TODO: should we only delete the PostContent and the activity? so as to preserve thread and nesting integrity

    object = repo().maybe_preload(object, [:media])
    delete_media = e(object, :media, [])

    opts
    |> Keyword.update(
      :delete_media,
      delete_media,
      &Enum.uniq(List.wrap(&1) ++ delete_media)
    )
    |> Keyword.put(
      :delete_associations,
      # adds per-type assocs
      (opts[:delete_associations] || []) ++
        [
          :post_content
        ]
    )
    |> run_epic(:delete, ..., :object)
  end

  @doc """
  Runs a series of post `Bonfire.Epics` operations based on configured acts for this module.

  ## Parameters

  - `type`: The type of epic operation to run.
  - `options`: Options for the epic operation.
  - `on`: The key in the epic assigns to return (default: `:post`).

  ## Returns

  `{:ok, result}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Posts.run_epic(:publish, [])
      {:ok, %Post{}}
  """
  def run_epic(type, options \\ [], on \\ :post) do
    Bonfire.Epics.run_epic(__MODULE__, type, Keyword.put(options, :on, on))
  end

  # def reply(creator, attrs) do
  #   with  {:ok, published} <- publish(creator, attrs),
  #         {:ok, r} <- get_replied(published.post.id) do
  #     reply = Map.merge(r, published)
  #     # |> IO.inspect
  #     PubSub.broadcast(e(reply, :thread_id, nil), {{Bonfire.Social.Threads.LiveHandler, :new_reply}, reply}) # push to online users

  #     {:ok, reply}
  #   end
  # end

  @doc """
  Creates a changeset for a post.

  ## Parameters

  - `action`: The action to perform (`:create`).
  - `attrs`: Attributes for the post.

  ## Returns

  A `%Changeset{}` for the post.

  ## Examples

      iex> Bonfire.Posts.changeset(:create, %{title: "New Post"})
  """
  def changeset(action, attrs, creator \\ nil, preset \\ nil)

  def changeset(:create, attrs, _creator, _preset) when attrs == %{} do
    # keep it simple for forms
    Post.changeset(%Post{}, attrs)
  end

  def changeset(:create, attrs, _creator, _preset_or_custom_boundary) do
    attrs
    |> prepare_post_attrs()
    |> debug("post_attrs")
    |> Post.changeset(%Post{}, ...)
  end

  def prepare_post_attrs(attrs) do
    # FIXME: find a less nasty way (this is to support graceful degradation with the textarea inside noscript)
    attrs
    |> debug("pre")
    |> deep_merge(%{
      post: %{
        post_content: %{
          html_body:
            e(attrs, :html_body, nil) || e(attrs, :post, :post_content, :html_body, nil) ||
              e(attrs, :fallback_post, :post_content, :html_body, nil)
        }
      }
    })
  end

  @doc """
  Attempts to fetch a post by its ID, if the current user has permission to read it.

  ## Parameters

  - `post_id`: The ID of the post to read.
  - `opts`: Options, incl. current user.

  ## Returns

  The post if found, `nil` otherwise.

  ## Examples

      iex> Bonfire.Posts.read("post_123")
      %Post{}
  """
  def read(post_id, opts \\ [])
      when is_binary(post_id) do
    opts =
      to_options(opts)
      |> Keyword.put(:verbs, [:read])

    query([id: post_id], opts)
    |> Objects.read(
      opts
      |> Keyword.put(:skip_boundary_check, true)
      # ^ avoid checking boundary twice
    )
  end

  @doc """
  Lists posts created by a user that are in their outbox and are not replies.

  ## Parameters

  - `by_user`: The user whose posts to list.
  - `opts`: Options for listing posts.

  ## Returns

  A list of posts.

  ## Examples

      iex> Bonfire.Posts.list_by(user)
      [%Post{}, %Post{}]
  """
  def list_by(by_user, opts \\ []) do
    # query FeedPublish
    # [posts_by: {by_user, &filter/3}]
    Objects.maybe_filter(query_base(), {:creators, by_user})
    |> list_paginated(to_options(opts) ++ [subject_user: by_user])
  end

  @doc """
  Lists posts with pagination.

  ## Parameters

  - `filters`: Filters to apply to the query.
  - `opts`: Options for pagination.

  ## Returns

  A paginated list of posts.

  ## Examples

      iex> Bonfire.Posts.list_paginated([])
      %{edges: [%Post{}, %Post{}], page_info: %{}}
  """
  def list_paginated(filters, opts \\ [])

  def list_paginated(filters, opts)
      when is_list(filters) or is_struct(filters) do
    filters
    # |> debug("filters")
    |> query_paginated(opts)
    |> Objects.list_paginated(opts)
  end

  @doc """
  Queries posts with pagination.

  ## Parameters

  - `filters`: Filters to apply to the query.
  - `opts`: Options for pagination.

  ## Returns

  A paginated query for posts.

  ## Examples

      iex> Bonfire.Posts.query_paginated([])
      #Ecto.Query<>
  """
  def query_paginated(filters, opts \\ [])

  def query_paginated([], opts), do: query_paginated(query_base(), opts)

  def query_paginated(filters, opts)
      when is_list(filters) or is_struct(filters) do
    # |> debug("filters")
    Objects.list_query(filters, opts)
    # |> proload([:post_content])

    # |> FeedActivities.query_paginated(opts, Post)
    # |> debug("after FeedActivities.query_paginated")
  end

  # query_paginated(filters \\ [], current_user_or_socket_or_opts \\ [],  query \\ FeedPublish)
  def query_paginated({a, b}, opts), do: query_paginated([{a, b}], opts)

  @doc """
  Queries posts.

  ## Parameters

  - `filters`: Filters to apply to the query.
  - `opts`: Query options.

  ## Returns

  An Ecto query for posts.

  ## Examples

      iex> Bonfire.Posts.query([id: "post_123"])
      #Ecto.Query<>
  """
  def query(filters \\ [], opts \\ nil)

  def query(filters, opts) when is_list(filters) or is_tuple(filters) do
    query_base()
    |> query_filter(filters, nil, nil)
    |> boundarise(main_object.id, opts)
  end

  defp query_base do
    from(main_object in Post, as: :main_object)
    |> proload([:post_content])
  end

  @doc """
  Searches for posts.

  ## Parameters

  - `search`: The search term to look for in the title, summary, or body.
  - `opts`: Search options.

  ## Returns

  A list of matching posts.

  ## Examples

      iex> Bonfire.Posts.search("example")
      [%Post{}, %Post{}]
  """
  def search(search, opts \\ []) do
    Utils.maybe_apply(
      Bonfire.Search,
      :search_by_type,
      [search, Post, opts],
      &none/2
    ) ||
      search_query(search, opts) |> Social.many(opts[:paginate?], opts)
  end

  defp none(_, _), do: nil

  def search_query(search, opts \\ []), do: Bonfire.Social.PostContents.search_query(search, opts)

  @doc """
  Publishes an ActivityPub activity for a post.

  ## Parameters

  - `subject`: The subject of the activity.
  - `verb`: The verb of the activity.
  - `post`: The post to publish.

  ## Returns

  `{:ok, activity}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Posts.ap_publish_activity(user, :create, post)
      {:ok, %ActivityPub.Activity{}}
  """
  # TODO: federated delete, in addition to create:
  def ap_publish_activity(subject, verb, post) do
    id = uid!(post)

    post =
      post
      |> repo().maybe_preload([
        :post_content,
        :media,
        :created,
        :sensitive,
        replied: [thread: [:created], reply_to: [:created]],
        tags: [:character]
      ])
      |> Activities.object_preload_create_activity()
      |> debug("post to federate")

    subject =
      subject ||
        e(post, :created, :creator, nil) ||
        e(post, :created, :creator_id, nil) || e(post, :activity, :subject, nil) ||
        e(post, :activity, :subject_id, nil)

    thread_creator =
      e(post, :replied, :thread, :created, :creator, nil) ||
        e(post, :replied, :thread, :created, :creator_id, nil)

    reply_to_creator =
      (e(post, :replied, :reply_to, :created, :creator, nil) ||
         e(post, :replied, :reply_to, :created, :creator_id, nil))
      |> debug("reply_to_creator")

    # TODO: should we just include ALL thread participants? ^

    is_public = Bonfire.Boundaries.object_public?(post)

    to =
      if is_public do
        ["https://www.w3.org/ns/activitystreams#Public"]
      else
        []
      end

    thread_id = e(post, :replied, :thread_id, nil)
    reply_to_id = e(post, :replied, :reply_to_id, nil)

    with {:ok, actor} <-
           ActivityPub.Actor.get_cached(pointer: subject),

         # TODO: find a better way of deleting non-actor entries from the list
         # (or better: represent them in AP)
         # Note: `mentions` preset adds grants to mentioned people which should trigger the boundaries-based logic in `Adapter.external_followers_for_activity`, so should we use this only for tagging and not for addressing (if we expand the scope of that function beyond followers)?
         hashtags <-
           e(post, :tags, [])
           #  |> info("tags")
           #  non-characters
           |> Enum.reject(fn tag ->
             not is_nil(e(tag, :character, nil))
           end)
           |> filter_empty([])
           |> Bonfire.Common.Needles.list!(skip_boundary_check: true)
           #  |> repo().maybe_preload(:named)
           |> debug("include_as_hashtags"),
         mentions <-
           e(post, :tags, [])
           |> debug("tags")
           #  characters except me
           |> Enum.reject(fn tag ->
             is_nil(e(tag, :character, nil)) or id(tag) == id(subject)
           end)
           |> debug("mentions to actors")
           |> Enum.map(&ActivityPub.Actor.get_cached!(pointer: &1))
           |> filter_empty([])
           |> debug("include_as_tags"),
         # TODO: put much of this logic somewhere reusable by objects other than Post, eg `Bonfire.Federate.ActivityPub.AdapterUtils.determine_recipients/4`
         # TODO: add a followers-only preset?
         #  (if is_public do
         #     mentions ++ List.wrap(actor.data["followers"])
         #   else
         cc <-
           [reply_to_creator, thread_creator]
           #  |> info("tags")
           |> Enums.uniq_by_id()
           |> Enum.reject(fn u ->
             id(u) == id(subject)
           end)
           |> Enum.map(&ActivityPub.Actor.get_cached!(pointer: &1))
           |> Enum.concat(mentions)
           |> Enums.uniq_by_id()
           |> debug("mentions to recipients")
           |> Enum.map(& &1.ap_id)
           |> debug("direct_recipients"),
         # end),
         bcc <- [],
         context <- if(thread_id && thread_id != id, do: Threads.ap_prepare(thread_id)),
         #  to <- to ++ Enum.map(mentions, fn actor -> actor.ap_id end),
         object <-
           %{
             "type" => "Note",
             "actor" => actor.ap_id,
             "attributedTo" => actor.ap_id,
             "to" => to,
             "cc" => cc,
             # TODO: put somewhere reusable by other types:
             "indexable" =>
               Bonfire.Common.Extend.module_enabled?(Bonfire.Search.Indexer, subject),
             # TODO: put somewhere reusable by other types:
             "sensitive" => e(post, :sensitive, :is_sensitive, false),
             "name" => e(post, :post_content, :name, nil),
             "summary" => e(post, :post_content, :summary, nil),
             "content" =>
               Text.maybe_markdown_to_html(
                 e(post, :post_content, :html_body, nil),
                 # we don't want to escape HTML in local content
                 sanitize: true
               ),
             "attachment" => Bonfire.Files.ap_publish_activity(e(post, :media, nil)),
             # TODO support replies and context for all object types, not just posts
             "inReplyTo" =>
               if(reply_to_id == thread_id, do: context) ||
                 if(reply_to_id != id, do: Threads.ap_prepare(reply_to_id)),
             "context" => context,
             "tag" =>
               Enum.map(mentions, fn actor ->
                 %{
                   "href" => actor.ap_id,
                   "name" => actor.username,
                   "type" => "Mention"
                 }
               end) ++
                 Enum.map(hashtags, fn tag ->
                   %{
                     "href" => URIs.canonical_url(tag),
                     "name" => "##{e(tag, :name, nil) || e(tag, :named, :name, nil)}",
                     "type" => "Hashtag"
                   }
                 end)
           }
           |> Enum.filter(fn {_, v} -> not is_nil(v) end)
           |> Enum.into(%{}),
         params <-
           %{
             pointer: id,
             local: true,
             actor: actor,
             context: context,
             to: to,
             published:
               DatesTimes.date_from_pointer(id)
               |> DateTime.to_iso8601(),
             additional: %{
               "cc" => cc,
               "bcc" => bcc
             }
           },
         {:ok, activity} <-
           ap_create_or_update(verb, params, object) |> debug("ap_created_or_updated") do
      {:ok, activity}
    end
  end

  defp ap_create_or_update(:edit, params, object) do
    ActivityPub.update(
      params
      |> Map.merge(%{
        object:
          Map.put_new(
            object,
            "updated",
            DateTime.utc_now()
            |> DateTime.to_iso8601()
          )
      })
      |> debug("params for ActivityPub / edit - Update")
    )
  end

  defp ap_create_or_update(other_verb, params, object) do
    ActivityPub.create(
      params
      |> Map.merge(%{
        object: object
      })
      |> debug("params for ActivityPub / #{inspect(other_verb)}")
    )
  end

  @doc """
  Receives an incoming ActivityPub post.

  ## Parameters

  - `creator`: The creator of the post.
  - `activity`: The ActivityPub activity.
  - `object`: The ActivityPub object.
  - `circles`: The circles to publish to (default: `[]`).

  ## Returns

  `{:ok, post}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Posts.ap_receive_activity(creator, activity, object)
      {:ok, %Post{}}
  """
  def ap_receive_activity(
        creator,
        ap_activity,
        ap_object
      )
      when not is_nil(creator) do
    # debug(activity: activity)
    # debug(creator: creator)
    # debug(object: object)

    activity_data = e(ap_activity, :data, %{})
    post_data = e(ap_object, :data, %{})
    id = e(ap_object, :pointer_id, nil)

    reply_to_ap_object = Threads.reply_to_ap_object(activity_data, post_data)

    reply_to_id =
      e(reply_to_ap_object, :pointer_id, nil)
      |> debug("reply_to_id")

    is_public? = Bonfire.Federate.ActivityPub.AdapterUtils.is_public?(ap_activity, ap_object)

    direct_recipients =
      Bonfire.Federate.ActivityPub.AdapterUtils.all_known_recipient_characters(
        activity_data,
        post_data
      )

    {boundary, to_circles} =
      Bonfire.Federate.ActivityPub.AdapterUtils.recipients_boundary_circles(
        direct_recipients,
        is_public?
      )

    attrs =
      Bonfire.Social.PostContents.ap_receive_attrs_prepare(
        creator,
        activity_data,
        post_data,
        direct_recipients
      )
      |> Enum.into(%{
        id: id,
        # huh?
        canonical_url: nil,
        #  needed here for Messages
        to_circles: to_circles,
        reply_to_id: reply_to_id
      })

    if !is_public? and not Enum.empty?(to_circles || []) and
         (!reply_to_id or
            Bonfire.Common.Types.object_type(
              repo().maybe_preload(reply_to_ap_object, :pointer)
              |> e(:pointer, nil)
            )
            |> debug("replying_to_type") ==
              Bonfire.Data.Social.Message) do
      info("treat as Message if private with @ mentions that isn't a reply to a non-DM")
      maybe_apply(Bonfire.Messages, :send, [creator, attrs])
    else
      publish(
        Keyword.merge(attrs[:opts] || [],
          local: false,
          current_user: creator,
          post_attrs: attrs,
          boundary: boundary,
          to_circles: to_circles,
          post_id: id
        )
      )
    end
  end

  @doc """
  Formats a post for search indexing.

  ## Parameters

  - `post`: The post to format.
  - `opts`: Formatting options.

  ## Returns

  A map with formatted post data for indexing.

  ## Examples

      iex> Bonfire.Posts.indexing_object_format(post)
      %{id: "post_123", index_type: "Bonfire.Data.Social.Post", post_content: %{}, created: %{}, tags: []}
  """
  def indexing_object_format(object) do
    content = e(object, :post_content, nil) |> debug()
    activity = e(object, :activity, nil) |> debug()

    replied =
      e(object, :replied, nil) || e(activity, :replied, nil) ||
        repo().maybe_preload(object, :replied) |> e(:replied, nil)

    %{
      "id" => id(object),
      "index_type" => Types.module_to_str(Bonfire.Data.Social.Post),
      "post_content" => Bonfire.Social.PostContents.indexing_object_format(content),
      # TODO: put the the following fields somewhere reusable across object types, maybe attach as Activity?
      "replied" => %{
        # TODO: can we assume the type and ID for mixins? to avoid storing extra data in the index
        # "id" => id, # no need as can be inferred later by `Enums.maybe_to_structs/1`
        # "index_type" => Types.module_to_str(Replied),
        "thread_id" => e(replied, :thread_id, nil),
        "reply_to_id" => e(replied, :reply_to_id, nil)
      },
      "created" =>
        maybe_apply(Bonfire.Me.Integration, :indexing_format_created, [object],
          fallback_return: nil
        ),
      "tags" => maybe_apply(Tags, :indexing_format_tags, activity || content, fallback_return: [])
    }
    |> debug()

    # "url" => path(post),
  end

  def count_total(), do: repo().one(select(Post, [u], count(u.id)))
end
