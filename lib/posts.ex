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
  alias Bonfire.Social.PostContents
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
      "Article",
      "ChatMessage",
      {"Create", "Note"},
      {"Update", "Note"},
      {"Create", "Article"},
      {"Update", "Article"}
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

  def publish(post_attrs, opts) do
    publish(to_options(opts) |> Keyword.put(:post_attrs, post_attrs))
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

  def changeset(_, attrs, _creator, _preset) when attrs == %{} do
    # keep it simple for forms
    Post.changeset(%Post{}, attrs)
  end

  def changeset(:create, attrs, _creator, _preset_or_custom_boundary) do
    attrs
    |> prepare_post_attrs()
    |> debug("post_attrs")
    |> Post.changeset(%Post{}, ...)
  end

  def changeset(_, attrs, _creator, _preset_or_custom_boundary) do
    Post.changeset(%Post{}, attrs)
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
      # ^ to avoid checking boundary twice
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
    Objects.maybe_filter(query_base(opts), {:creators, by_user})
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

  def query_paginated([], opts), do: query_paginated(query_base(opts), opts)

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
    query_base(opts)
    |> query_filter(filters, nil, nil)
    |> boundarise(main_object.id, opts)
  end

  defp query_base(opts) do
    from(main_object in Post, as: :main_object)
    |> repo().maybe_filter_out_future_ulids(opts)
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

    reply_to_id = e(post, :replied, :reply_to_id, nil)

    is_public = Bonfire.Boundaries.object_public?(post)

    interaction_policy =
      Bonfire.Federate.ActivityPub.AdapterUtils.ap_prepare_outgoing_interaction_policy(
        subject,
        post
      )

    to =
      if is_public do
        [Bonfire.Federate.ActivityPub.AdapterUtils.public_uri()]
      else
        []
      end

    thread_id = e(post, :replied, :thread_id, nil)

    with {:ok, actor} <-
           ActivityPub.Actor.get_cached(pointer: subject),
         # TODO: find a better way of deleting non-actor entries from the list
         # (or better: represent them in AP)
         # Note: `mentions` preset adds grants to mentioned people which should trigger the boundaries-based logic in `Adapter.external_followers_for_activity`, so should we use this only for tagging and not for addressing (if we expand the scope of that function beyond followers)?
         mentions <-
           post
           |> debug("tags")
           |> Bonfire.Social.Tags.list_tags_mentions(subject)
           |> debug("list_tags_mentions")
           |> Enum.map(&ActivityPub.Actor.get_cached!(pointer: &1))
           |> filter_empty([])
           |> debug("mentions to actors"),
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
           |> flood("direct_recipients"),
         # end),
         context <- if(thread_id && thread_id != id, do: Threads.ap_prepare(thread_id)),
         reply_to <-
           if(reply_to_id == thread_id, do: context) ||
             if(reply_to_id && reply_to_id != id, do: Threads.ap_prepare(reply_to_id)),
         # TODO ^ support replies and context for all object types, not just posts
         object <-
           PostContents.ap_prepare_object_note(
             subject,
             verb,
             post,
             actor,
             mentions,
             context,
             reply_to
           ),
         ap_id = object["id"] || URIs.canonical_url(post),
         params <-
           %{
             pointer: id,
             local: true,
             actor: actor,
             context: context,
             published:
               DatesTimes.date_from_pointer(id)
               |> DateTime.to_iso8601(),
             to: to,
             additional: %{
               "cc" => cc
             },
             object:
               (maybe_note_to_article(object, ap_id) || object)
               |> Map.merge(%{
                 "id" => ap_id,
                 "to" => to,
                 "cc" => cc,
                 "interactionPolicy" => interaction_policy
               })
           },
         {:ok, activity} <-
           ap_create_or_update(
             verb,
             params
           ) do
      {:ok, activity}
    end
  end

  def maybe_note_to_article(object, url) do
    name = object["name"]
    content = object["content"]

    if is_binary(name) and
         byte_size(name) > 2 and
         String.length(content || "") > Bonfire.Social.Activities.article_char_threshold() do
      custom_summary = object["summary"]

      summary =
        custom_summary ||
          Text.sentence_truncate(Text.text_only(Text.maybe_markdown_to_html(content)), 500)

      # Create simplified preview Note with only essential fields
      preview =
        %{
          "type" => "Note",
          "name" => name,
          "summary" => summary,
          "content" => content
        }
        |> Enum.filter(fn {_, v} -> not is_nil(v) end)
        |> Enum.into(%{})

      # Find first image attachment for cover image
      # first_image =
      #   object["attachment"]
      #   |> List.wrap()
      #   |> Enum.find(fn attachment ->
      #     case attachment do
      #       %{"mediaType" => media_type} -> String.starts_with?(media_type, "image/")
      #       %{"type" => "Image"} -> true
      #       _ -> false
      #     end
      #   end)

      # Convert Note to Article and embed simplified Note as preview
      object
      |> Map.put("type", "Article")
      # make sure we have summary where Masto expects it
      |> Map.put("summary", summary)
      # avoid duplicating the content in both fields
      |> Map.put("content", content)
      # Add url field pointing to the object's id
      |> Map.put("url", url)
      # Add first image if any as cover image - TODO: have the user select which one?
      |> Map.put("preview", preview)
    end
  end

  defp ap_create_or_update(edit_verb, params) when edit_verb in [:edit, :update] do
    ActivityPub.update(
      params
      |> flood("params for ActivityPub / edit - Update")
    )
  end

  defp ap_create_or_update(other_verb, params) do
    ActivityPub.create(
      params
      |> flood("params for ActivityPub / #{inspect(other_verb)}")
    )
    |> flood("result of ActivityPub / #{inspect(other_verb)}")
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
        %{data: %{"type" => "Update"} = activity_data} = _ap_activity,
        ap_object
      ) do
    # debug(activity_data, "do_an_update")
    post_data = e(ap_object, :data, %{})

    #  with %{pointer_id: pointer_id} = _original_object when is_binary(pointer_id) <-
    #    ActivityPub.Object.get_activity_for_object_ap_id(post_data) do
    with {:ok, original_pointer, pointer_id} <- get_pointer_to_update(ap_object),
         true <-
           is_binary(pointer_id) ||
             error(:not_found, "No pointer_id in the object so we can't find it to update"),
         {:ok, post} <- original_pointer || read(pointer_id, skip_boundary_check: true),
         _ = debug(post, "post before update"),
         {:ok, attrs, updated_post_content} <-
           PostContents.ap_receive_update(creator, activity_data, post_data, pointer_id),
         _ = debug(attrs, "attrs from ap_receive_update"),
         _ = debug(updated_post_content, "updated_post_content from ap_receive_update"),
         post =
           post
           |> Map.put(:post_content, updated_post_content) do
      # Update metadata too: sensitive, hashtags, mentions, media

      update_post_assocs(creator, post, attrs)
      |> debug("result from update_post_assocs")

      # else
      #   e ->
      #     error(e, "Could not find the object being updated.")
    end
  end

  defp get_pointer_to_update(ap_object) do
    post_data = e(ap_object, :data, %{})

    with {:ok, %{pointer_id: pointer_id} = original_object} <-
           ActivityPub.Object.get_cached(ap_id: post_data),
         original_pointer = e(original_object, :pointer, nil),
         pointer_id =
           pointer_id || Enums.id(original_pointer) ||
             Bonfire.Social.Objects.pointer_id_from_ap_object(ap_object) do
      {:ok, original_pointer, pointer_id}
    else
      {:error, :not_found} ->
        if pointer_id = Bonfire.Social.Objects.pointer_id_from_ap_object(ap_object) do
          {:ok, nil, pointer_id}
        else
          error(ap_object, "Could not find the object being updated.")
          {:error, :not_found}
        end

      e ->
        error(e, "Error while looking for the object being updated.")
    end
  end

  def ap_receive_activity(
        creator,
        ap_activity,
        ap_object
      )
      when not is_nil(creator) do
    # debug(creator: creator)
    # debug(ap_activity, "ap_receive_activity: Create")
    # debug(ap_object, "ap_object")

    activity_data = e(ap_activity, :data, %{})
    post_data = e(ap_object, :data, %{})
    id = e(ap_object, :pointer_id, nil)

    reply_to_ap_object = Threads.reply_to_ap_object(activity_data, post_data)

    reply_to_id =
      e(reply_to_ap_object, :pointer_id, nil)

    is_public? =
      Bonfire.Federate.ActivityPub.AdapterUtils.is_public?(ap_activity, ap_object)
      |> flood("is_public?")

    direct_recipients =
      Bonfire.Federate.ActivityPub.AdapterUtils.all_known_recipient_characters(
        activity_data,
        post_data
      )
      |> flood("direct_recipients")

    {boundary, to_circles} =
      Bonfire.Federate.ActivityPub.AdapterUtils.recipients_boundary_circles(
        direct_recipients,
        ap_activity,
        is_public?,
        post_data["interactionPolicy"]
      )
      |> flood("boundary & to_circles")

    attrs =
      PostContents.ap_receive_attrs_prepare(
        creator,
        activity_data,
        post_data,
        direct_recipients
      )

    attrs =
      Map.merge(attrs, %{
        id: id,
        # huh?
        canonical_url: nil,
        #  needed here for Messages
        to_circles: to_circles,
        reply_to_id: reply_to_id,
        uploaded_media:
          Bonfire.Files.ap_receive_attachments(
            creator,
            attrs[:primary_image],
            attrs[:attachments] |> debug("ap_attachments")
          )
          |> debug("ap_receive_attachments done")
      })
      |> debug("attrs for incoming post creation")

    # debug(to_circles, "to_circles")
    # debug(reply_to_id, "reply_to_id")

    if !is_public? and not Enum.empty?(to_circles || []) and
         (!reply_to_id or
            Bonfire.Common.Types.object_type(
              repo().maybe_preload(reply_to_ap_object, :pointer)
              |> e(:pointer, nil)
            )
            |> debug("replying_to_type") ==
              Bonfire.Data.Social.Message) do
      debug("treat as Message if private with @ mentions that isn't a reply to a non-DM")
      maybe_apply(Bonfire.Messages, :send, [creator, attrs])
    else
      info(is_public?, "treat as Post - public?")

      publish(
        Keyword.merge(attrs[:opts] || [],
          local: false,
          current_user: creator,
          post_attrs: attrs,
          boundary: boundary,
          to_circles: to_circles,
          verbs_to_grant: if(!is_public?, do: Config.get([:verbs_to_grant, :message])),
          post_id: id
        )
        |> debug("opts for incoming post epic")
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

    sensitive =
      Map.get(
        if(is_map(activity), do: activity, else: %{}),
        :sensitive,
        Map.get(if(is_map(object), do: object, else: %{}), :sensitive, nil)
      )

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
      "sensitive" => e(sensitive, :is_sensitive, nil),
      "created" =>
        maybe_apply(Bonfire.Me.Integration, :indexing_format_created, [object],
          fallback_return: nil
        )
      # "tags" => maybe_apply(Tags, :indexing_format_tags, activity || object, fallback_return: []) # NOTE: no need to index tags separately as they are in the body
    }
    |> debug()

    # "url" => path(post),
  end

  def count_total(), do: repo().one(select(Post, [u], count(u.id)))

  defp query_for_creator(user_ids) do
    from(c in Bonfire.Data.Social.Created,
      join: p in Bonfire.Data.Social.Post,
      on: c.id == p.id,
      where: c.creator_id in ^List.wrap(user_ids),
      group_by: c.creator_id
    )
  end

  def count_for_users(users) when is_list(users) do
    user_ids =
      users
      |> Types.uids()
      |> Enum.uniq()

    if user_ids == [] do
      %{}
    else
      user_ids
      |> query_for_creator()
      |> select([c], {c.creator_id, count(c.id)})
      |> repo().all()
      |> Map.new()
    end
  end

  def count_for_users(_), do: %{}

  @doc """
  Count posts created by a single user.

  Returns the number of posts as an integer, or nil if the user has no posts.

  ## Examples

      iex> count_for_user(user_id)
      42

      iex> count_for_user(nonexistent_user)
      nil
  """
  def count_for_user(user) do
    if user_id = Types.uid(user) do
      user_id
      |> query_for_creator()
      |> select([c], count(c.id))
      |> repo().one()
    end
  end

  # Helper function to update post metadata during Update activities
  defp update_post_assocs(creator, %{id: _pointer_id} = post, attrs) do
    post =
      post
      |> repo().maybe_preload([:sensitive, :tags, :media])
      |> debug("post with old assocs preloaded")

    with {:ok, post} <- Objects.set_sensitivity(post, attrs[:sensitive]) || {:ok, post},
         {:ok, post} <- Bonfire.Tag.maybe_update_tags(creator, post, attrs) || {:ok, post},
         post = repo().preload(post, :files),
         {:ok, post} <-
           Bonfire.Files.maybe_update_media_assoc(creator, post, update_changeset(post), attrs) ||
             {:ok, post} do
      {:ok,
       post
       |> repo().maybe_preload([:sensitive, :tags, :media], force: true)}
    end
  end

  def update_changeset(%{} = post, attrs \\ %{}) do
    Post.changeset(post, attrs)
  end

  def update(post, attrs \\ %{})

  def update(%Ecto.Changeset{} = changeset, _) do
    changeset
    |> repo().update()
  end

  def update(post, attrs) do
    update_changeset(post, attrs)
    |> update()
  end
end
