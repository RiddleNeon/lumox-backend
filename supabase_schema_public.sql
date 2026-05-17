--
-- PostgreSQL database dump
--

\restrict pYYZY8AGZPdChPLsIIMsKIbe35dYKUO7tzkZGL62RSZCMOW0jZWgku1KnDuSmc5

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.9

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: __create_conversation(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.__create_conversation(p_type text, p_title text DEFAULT NULL::text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
  v_conversation_id bigint;
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid(); 

  INSERT INTO public.conversations (type, created_by, title)
  VALUES (p_type, v_user_id, p_title)
  RETURNING id INTO v_conversation_id;
  
  INSERT INTO public.conversation_members (conversation_id, profile_id, role)
  VALUES (v_conversation_id, v_user_id, 'admin');
  
  RETURN v_conversation_id;
END;$$;


--
-- Name: _get_comments_with_like(bigint, uuid, bigint, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._get_comments_with_like(p_video_id bigint, p_current_user uuid, p_parent_id bigint, p_limit integer, p_offset integer) RETURNS record
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$select
    c.id,
    c.author_id,
    c.video_id,
    c.content,
    c.created_at,
    c.parent_id,
    c.reply_count,
    c.like_count,
    row_to_json(p) as profiles,
    exists (
      select 1
      from public.comment_likes cl
      where cl.comment_id = c.id and cl.user_id = p_current_user
    ) as liked_by_current_user
  from public.comments c
  join public.profiles p on p.id = c.author_id
  where c.video_id = p_video_id
    and (
      (p_parent_id is null and c.parent_id is null)
      or (p_parent_id is not null and c.parent_id = p_parent_id)
    )
  order by c.like_count desc
  limit p_limit offset p_offset;$$;


--
-- Name: _increment_video_metric(bigint, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._increment_video_metric(p_video_id bigint, p_column text, p_delta integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
begin
  if p_column not in ('view_count') then
    raise exception 'unsupported video metric %', p_column;
  end if;

  execute format(
    'update public.videos set %I = greatest(coalesce(%I, 0) + $1, 0) where id = $2',
    p_column,
    p_column
  ) using p_delta, p_video_id;
end;
$_$;


--
-- Name: appeal_ban(text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.appeal_ban(p_appeal_message text, p_user_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$BEGIN
  INSERT INTO ban_appeals (user_id, appeal_message) VALUES (p_user_id, p_appeal_message);

  UPDATE profiles set is_banned = false where id = p_user_id;
END$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: task_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_versions (
    id bigint NOT NULL,
    task_id bigint NOT NULL,
    version_no integer NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    title text DEFAULT 'No Title Provided'::text NOT NULL,
    ui jsonb DEFAULT '{}'::jsonb NOT NULL,
    logic jsonb DEFAULT '{"pass": {"min_score": 0}, "rules": []}'::jsonb NOT NULL,
    created_by uuid DEFAULT auth.uid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    published_at timestamp with time zone,
    CONSTRAINT task_versions_logic_check CHECK ((jsonb_typeof(logic) = 'object'::text)),
    CONSTRAINT task_versions_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text, 'archived'::text]))),
    CONSTRAINT task_versions_ui_check CHECK ((jsonb_typeof(ui) = 'object'::text))
);


--
-- Name: clone_task_version(bigint, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clone_task_version(p_task_id bigint, p_source_version_id bigint, p_new_title text DEFAULT NULL::text) RETURNS public.task_versions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_source public.task_versions;
  v_next integer;
  v_row public.task_versions;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1 from public.tasks t where t.id = p_task_id and t.created_by = v_uid
  ) then
    raise exception 'Only owner can clone versions';
  end if;

  select *
    into v_source
  from public.task_versions
  where id = p_source_version_id
    and task_id = p_task_id;

  if not found then
    raise exception 'Source version not found';
  end if;

  select coalesce(max(version_no), 0) + 1
  into v_next
  from public.task_versions
  where task_id = p_task_id;

  insert into public.task_versions(task_id, version_no, status, title, ui, logic, created_by)
  values (
    p_task_id,
    v_next,
    'draft',
    coalesce(p_new_title, v_source.title || ' (copy)'),
    v_source.ui,
    v_source.logic,
    v_uid
  )
  returning * into v_row;

  return v_row;
end;
$$;


--
-- Name: contains_banned_word(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contains_banned_word(p_content text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $_$declare
  v_word text;
begin
  for v_word in
    select word from public.banned_words
  loop
    if lower(p_content) ~ ('(^|[^a-zA-Z0-9])' || regexp_replace(lower(v_word), '([.^$*+?(){}\[\]\\|])', '\\\1', 'g') || '([^a-zA-Z0-9]|$)') then
      return true;
    end if;
  end loop;

  return false;
end;$_$;


--
-- Name: count_search_profiles(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.count_search_profiles(search_query text) RETURNS bigint
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$SELECT COUNT(p.*)
FROM profiles p
WHERE
  p.username ILIKE '%' || search_query || '%'
  OR p.display_name ILIKE '%' || search_query || '%'$$;


--
-- Name: count_search_videos(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.count_search_videos(search_query text) RETURNS bigint
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$SELECT COUNT(*)
FROM videos v
WHERE v.is_published = true
  AND (
    v.title ILIKE '%' || search_query || '%'
    OR v.description ILIKE '%' || search_query || '%'
    OR EXISTS (
      SELECT 1
      FROM video_tags vt
      JOIN tags t ON t.id = vt.tag_id
      WHERE vt.video_id = v.id
        AND t.name ILIKE '%' || search_query || '%'
    )
  );$$;


--
-- Name: create_conversation(text, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_conversation(p_type text, p_receiver_id uuid, p_title text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
  v_conversation_id bigint;
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid(); 

  INSERT INTO public.conversations (type, created_by, title)
  VALUES (p_type, v_user_id, p_title)
  RETURNING id INTO v_conversation_id;
  
  INSERT INTO public.conversation_members (conversation_id, profile_id, role)
  VALUES (v_conversation_id, v_user_id, 'admin');

  IF p_receiver_id IS NOT NULL THEN
    INSERT INTO public.conversation_members (conversation_id, profile_id, role)
    VALUES (v_conversation_id, p_receiver_id, 'member');
  END IF;
  
  RETURN v_conversation_id;
END;$$;


--
-- Name: create_task_draft_version(bigint, text, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_task_draft_version(p_task_id bigint, p_title text, p_ui jsonb DEFAULT '{}'::jsonb, p_logic jsonb DEFAULT '{"pass": {"min_score": 0}, "rules": []}'::jsonb) RETURNS public.task_versions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_next integer;
  v_row public.task_versions;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1 from public.tasks t where t.id = p_task_id and t.created_by = v_uid
  ) then
    raise exception 'Only owner can create draft versions';
  end if;

  if not public.quiz_logic_is_valid(p_logic) then
    raise exception 'Invalid logic JSON';
  end if;

  if jsonb_typeof(p_ui) <> 'object' then
    raise exception 'UI JSON must be an object';
  end if;

  select coalesce(max(version_no), 0) + 1
  into v_next
  from public.task_versions
  where task_id = p_task_id;

  insert into public.task_versions(task_id, version_no, status, title, ui, logic, created_by)
  values (p_task_id, v_next, 'draft', coalesce(p_title, 'No Title Provided'), p_ui, p_logic, v_uid)
  returning * into v_row;

  return v_row;
end;
$$;


--
-- Name: delete_message(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_message(p_message_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_message public.messages;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select *
  into v_message
  from public.messages m
  where m.id = p_message_id
    and m.deleted_at is null
  for update;

  if not found then
    return;
  end if;

  if v_message.sender_id <> auth.uid() then
    raise exception 'Only the sender can delete this message' using errcode = '42501';
  end if;

  if not public.is_conversation_member(v_message.conversation_id) then
    raise exception 'Conversation access denied' using errcode = '42501';
  end if;

  update public.messages
  set deleted_at = now()
  where id = p_message_id;
end;
$$;


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    sender_id uuid,
    content text,
    type text DEFAULT 'text'::text NOT NULL,
    reply_to_message_id bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    edited_at timestamp with time zone
);


--
-- Name: edit_message(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.edit_message(p_message_id bigint, p_new_content text) RETURNS public.messages
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_message public.messages;
  v_content text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  v_content := trim(coalesce(p_new_content, ''));
  if v_content = '' then
    raise exception 'Message cannot be empty';
  end if;

  select *
  into v_message
  from public.messages m
  where m.id = p_message_id
    and m.deleted_at is null
  for update;

  if not found then
    raise exception 'Message not found';
  end if;

  if v_message.sender_id <> auth.uid() then
    raise exception 'Only the sender can edit this message' using errcode = '42501';
  end if;

  if not public.is_conversation_member(v_message.conversation_id) then
    raise exception 'Conversation access denied' using errcode = '42501';
  end if;

  update public.messages
  set
    content = v_content,
    edited_at = now()
  where id = p_message_id
  returning * into v_message;

  return v_message;
end;
$$;


--
-- Name: evaluate_task_submission(bigint, bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.evaluate_task_submission(p_task_id bigint, p_version_id bigint, p_answer_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_logic jsonb;
  v_answers jsonb;
  v_vars jsonb;
  v_rules jsonb;
  v_rule jsonb;
  v_when jsonb;
  v_then jsonb;
  v_else jsonb;
  v_passed boolean;
  v_trace jsonb := '[]'::jsonb;
  v_score numeric := 0;
  v_max_score numeric := 0;
  v_hard_fail boolean := false;
  v_pass_threshold numeric;
  v_is_correct boolean;
  v_xp_factor numeric := 0;
begin
  select tv.logic
    into v_logic
  from public.task_versions tv
  where tv.id = p_version_id
    and tv.task_id = p_task_id;

  if not found then
    raise exception 'Version % fuer Task % nicht gefunden', p_version_id, p_task_id;
  end if;

  if not public.quiz_logic_is_valid(v_logic) then
    raise exception 'Invalid logic JSON for task version %', p_version_id;
  end if;

  v_answers := case
    when p_answer_data ? 'answers' then coalesce(p_answer_data->'answers', '{}'::jsonb)
    else coalesce(p_answer_data, '{}'::jsonb)
  end;

  v_vars := coalesce(p_answer_data->'vars', '{}'::jsonb);
  v_rules := coalesce(v_logic->'rules', '[]'::jsonb);

  for v_rule in
    select value
    from jsonb_array_elements(case when jsonb_typeof(v_rules) = 'array' then v_rules else '[]'::jsonb end)
  loop
    v_when := coalesce(v_rule->'when', '{"op":"true"}'::jsonb);
    v_then := coalesce(v_rule->'then', '{}'::jsonb);
    v_else := coalesce(v_rule->'else', '{}'::jsonb);

    v_passed := public.quiz_eval_condition(v_when, v_answers, v_vars, jsonb_build_object('now', now()::text));

    if v_passed then
      if v_then ? 'max_score' then v_max_score := v_max_score + coalesce((v_then->>'max_score')::numeric, 0); end if;
      if v_then ? 'add_score' then v_score := v_score + coalesce((v_then->>'add_score')::numeric, 0); end if;
      if v_then ? 'set_vars' and jsonb_typeof(v_then->'set_vars') = 'object' then
        v_vars := v_vars || (v_then->'set_vars');
      end if;
      if lower(coalesce(v_then->>'fail', 'false')) = 'true' then v_hard_fail := true; end if;
    else
      if v_else ? 'max_score' then v_max_score := v_max_score + coalesce((v_else->>'max_score')::numeric, 0); end if;
      if v_else ? 'add_score' then v_score := v_score + coalesce((v_else->>'add_score')::numeric, 0); end if;
      if v_else ? 'set_vars' and jsonb_typeof(v_else->'set_vars') = 'object' then
        v_vars := v_vars || (v_else->'set_vars');
      end if;
      if lower(coalesce(v_else->>'fail', 'false')) = 'true' then v_hard_fail := true; end if;
    end if;

    v_trace := v_trace || jsonb_build_array(jsonb_build_object(
      'rule_id', coalesce(v_rule->>'id', md5(v_rule::text)),
      'passed', v_passed
    ));
  end loop;

  v_pass_threshold := nullif(coalesce(v_logic#>>'{pass,min_score}', ''), '')::numeric;
  if v_pass_threshold is null then
    v_pass_threshold := v_max_score;
  end if;

  v_is_correct := (not v_hard_fail) and (v_score >= coalesce(v_pass_threshold, 0));

  if v_max_score > 0 then
    v_xp_factor := greatest(least(v_score / v_max_score, 1), 0);
  else
    v_xp_factor := case when v_is_correct then 1 else 0 end;
  end if;

  return jsonb_build_object(
    'is_correct', v_is_correct,
    'score', v_score,
    'max_score', v_max_score,
    'pass_threshold', coalesce(v_pass_threshold, 0),
    'xp_factor', v_xp_factor,
    'vars', v_vars,
    'trace', v_trace
  );
end;
$$;


--
-- Name: get_comments_with_like(bigint, uuid, bigint, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_comments_with_like(p_video_id bigint, p_current_user uuid, p_parent_id bigint, p_limit integer, p_offset integer) RETURNS TABLE(id bigint, author_id uuid, video_id bigint, content character varying, created_at timestamp with time zone, parent_id bigint, reply_count integer, like_count integer, profiles json, liked_by_current_user boolean)
    LANGUAGE plpgsql STABLE
    AS $$
begin
  return query
  select
    c.id,
    c.author_id,
    c.video_id,
    c.content,
    c.created_at,
    c.parent_id,
    c.reply_count,
    c.like_count,
    row_to_json(p) as profiles,
    exists (
      select 1
      from public.comment_likes cl
      where cl.comment_id = c.id and cl.user_id = p_current_user
    ) as liked_by_current_user
  from public.comments c
  join public.profiles p on p.id = c.author_id
  where c.video_id = p_video_id
    and (
      (p_parent_id is null and c.parent_id is null)
      or (p_parent_id is not null and c.parent_id = p_parent_id)
    )
  order by c.like_count desc
  limit p_limit offset p_offset;
end;
$$;


--
-- Name: get_conversation_bot(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_conversation_bot(p_conversation_id bigint) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  select p.id
  from conversation_members cm
  join profiles p
    on p.id = cm.profile_id
  where cm.conversation_id = p_conversation_id
    and p.is_bot = true
  limit 1;
$$;


--
-- Name: video_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.video_tags (
    video_id bigint NOT NULL,
    tag_id integer NOT NULL
);


--
-- Name: get_filtered_video_tags(text, uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_filtered_video_tags(p_tag_name text, p_user_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS SETOF public.video_tags
    LANGUAGE sql STABLE
    AS $$
  SELECT vt.*
  FROM video_tags vt
  JOIN tags t ON t.id = vt.tag_id 
  WHERE t.name = p_tag_name
    AND (
      p_user_id IS NULL OR NOT EXISTS (
        SELECT 1
        FROM user_interactions ui
        WHERE ui.video_id = vt.video_id
          AND ui.user_id = p_user_id
      )
    )
  OFFSET p_offset
  LIMIT p_limit;
$$;


--
-- Name: get_followers_count(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_followers_count(user_id uuid) RETURNS integer
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$SELECT COUNT(*)::INTEGER
FROM follows
WHERE following_id = user_id;$$;


--
-- Name: get_following_count(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_following_count(user_id uuid) RETURNS integer
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$SELECT COUNT(*)::INTEGER
  FROM follows
  WHERE follower_id = user_id;$$;


--
-- Name: message_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_versions (
    id bigint NOT NULL,
    message_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    version_no integer NOT NULL,
    content text NOT NULL,
    edited_at timestamp with time zone DEFAULT now() NOT NULL,
    edited_by uuid,
    change_type text DEFAULT 'edit'::text NOT NULL,
    CONSTRAINT message_versions_change_type_check CHECK ((change_type = ANY (ARRAY['initial'::text, 'edit'::text, 'delete'::text])))
);


--
-- Name: get_message_versions(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_message_versions(p_message_id bigint) RETURNS SETOF public.message_versions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_conv_id bigint;
begin
  select conversation_id into v_conv_id
  from public.messages
  where id = p_message_id;

  if not public.is_current_user_admin() and not coalesce(public.is_conversation_member(v_conv_id), false) then
    raise exception 'Only admins or participants can access message history' using errcode = '42501';
  end if;

return query
select mv.*
from public.message_versions mv
where mv.message_id = p_message_id
order by mv.version_no desc;
end;
$$;


--
-- Name: get_my_jwt_sub(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_jwt_sub() RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$SELECT auth.uid();$$;


--
-- Name: videos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.videos (
    id bigint NOT NULL,
    author_id uuid NOT NULL,
    title character varying(100),
    description text,
    video_url text NOT NULL,
    thumbnail_url text,
    duration_s bigint,
    view_count bigint NOT NULL,
    like_count bigint NOT NULL,
    is_published boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    comment_count smallint NOT NULL,
    is_youtube boolean DEFAULT false NOT NULL,
    fts tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, (((COALESCE(title, ''::character varying))::text || ' '::text) || COALESCE(description, ''::text)))) STORED
);


--
-- Name: COLUMN videos.comment_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.videos.comment_count IS 'the total amount of comments on this video';


--
-- Name: COLUMN videos.is_youtube; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.videos.is_youtube IS 'if the video is a youtube video';


--
-- Name: get_new_videos(uuid, timestamp with time zone, integer, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_new_videos(p_user_id uuid DEFAULT NULL::uuid, p_cursor timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 20, p_only_unseen boolean DEFAULT false) RETURNS SETOF public.videos
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
  RETURN QUERY
  SELECT v.*
  FROM videos v
  WHERE v.is_published = true
    AND (p_cursor IS NULL OR v.created_at < p_cursor)
    AND (
      NOT p_only_unseen 
      OR p_user_id IS NULL 
      OR NOT EXISTS (
        SELECT 1 FROM user_interactions ui 
        WHERE ui.video_id = v.id AND ui.user_id = p_user_id
      )
    )
  ORDER BY v.created_at DESC
  LIMIT p_limit;
END;
$$;


--
-- Name: get_task_ui_schema_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_task_ui_schema_v1() RETURNS jsonb
    LANGUAGE sql STABLE
    AS $_$
  select jsonb_build_object(
    '$schema', 'https://json-schema.org/draft/2020-12/schema',
    'title', 'Task UI Schema v1',
    'type', 'object',
    'required', jsonb_build_array('version', 'screens'),
    'properties', jsonb_build_object(
      'version', jsonb_build_object('type', 'string', 'const', '1.0'),
      'theme', jsonb_build_object('type', 'object'),
      'screens', jsonb_build_object(
        'type', 'array',
        'items', jsonb_build_object(
          'type', 'object',
          'required', jsonb_build_array('id', 'elements'),
          'properties', jsonb_build_object(
            'id', jsonb_build_object('type', 'string'),
            'animation', jsonb_build_object('type', 'object'),
            'elements', jsonb_build_object(
              'type', 'array',
              'items', jsonb_build_object(
                'type', 'object',
                'required', jsonb_build_array('type', 'id'),
                'properties', jsonb_build_object(
                  'id', jsonb_build_object('type', 'string'),
                  'type', jsonb_build_object('type', 'string'),
                  'props', jsonb_build_object('type', 'object'),
                  'bind', jsonb_build_object('type', 'object')
                )
              )
            )
          )
        )
      )
    )
  );
$_$;


--
-- Name: get_trending_candidates(uuid, timestamp with time zone, integer, integer, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_trending_candidates(p_user_id uuid DEFAULT NULL::uuid, p_cursor timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 60, p_days_back integer DEFAULT 40, p_only_unseen boolean DEFAULT false) RETURNS SETOF public.videos
    LANGUAGE plpgsql STABLE
    AS $$BEGIN
  RETURN QUERY
  SELECT DISTINCT v.*
  FROM videos v
  WHERE v.is_published = true
    AND v.created_at >= (NOW() - (p_days_back || ' days')::interval)
    AND (p_cursor IS NULL OR v.created_at < p_cursor)
    AND (
      NOT p_only_unseen 
      OR NOT EXISTS (
        SELECT 1 FROM user_interactions ui 
        WHERE ui.video_id = v.id AND ui.user_id = p_user_id
      )
    )
  ORDER BY v.created_at DESC
  LIMIT p_limit;
END;$$;


--
-- Name: get_trending_candidates(integer, timestamp with time zone, boolean, uuid, boolean, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_trending_candidates(p_days_back integer, p_cursor timestamp with time zone, p_only_unseen boolean, p_user_id uuid, p_use_youtube boolean, p_limit integer) RETURNS SETOF public.videos
    LANGUAGE plpgsql
    AS $$DECLARE
  has_youtube_access boolean;
  effective_use_youtube boolean;
BEGIN
  has_youtube_access := EXISTS (
    SELECT 1 FROM pro_users pu
    WHERE pu.user_id = auth.uid()
  );

  effective_use_youtube :=  COALESCE(p_use_youtube, false) AND has_youtube_access;

  RETURN QUERY
  SELECT DISTINCT v.*
  FROM videos v
  WHERE v.is_published = true
    AND v.created_at >= (NOW() - (p_days_back || ' days')::interval)
    AND (p_cursor IS NULL OR v.created_at < p_cursor)
    AND (
      NOT p_only_unseen 
      OR NOT EXISTS (
        SELECT 1 
        FROM user_interactions ui 
        WHERE ui.video_id = v.id 
          AND ui.user_id = p_user_id
      )
    )
    AND (
      CASE 
        WHEN p_use_youtube = true AND has_youtube_access
          THEN v.is_youtube = true
        ELSE v.is_youtube = false
      END
    )
  ORDER BY v.created_at DESC
  LIMIT p_limit;
END;$$;


--
-- Name: get_videos_by_tag(text, uuid, integer, integer, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_videos_by_tag(p_tag_name text, p_user_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0, p_only_unseen boolean DEFAULT false) RETURNS SETOF public.videos
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
  RETURN QUERY
  SELECT v.*
  FROM videos v
  JOIN video_tags vt ON vt.video_id = v.id
  JOIN tags t ON t.id = vt.tag_id
  WHERE t.name = p_tag_name
    AND v.is_published = true
    AND (
      NOT p_only_unseen 
      OR p_user_id IS NULL 
      OR NOT EXISTS (
        SELECT 1 FROM user_interactions ui 
        WHERE ui.video_id = v.id AND ui.user_id = p_user_id
      )
    )
  ORDER BY v.created_at DESC
  LIMIT p_limit
  OFFSET p_offset;
END;
$$;


--
-- Name: increment_video_metric(bigint, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.increment_video_metric(p_video_id bigint, p_column text, p_delta integer) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $_$begin
  if p_column not in ('like_count', 'view_count', 'comment_count') then
    raise exception 'unsupported video metric %', p_column;
  end if;

  execute format(
    'update videos set %I = greatest(coalesce(%I, 0) + $1, 0) where id = $2',
    p_column,
    p_column
  ) using p_delta, p_video_id;
end;$_$;


--
-- Name: is_conversation_member(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_conversation_member(p_conversation_id bigint) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists(
    select 1
    from public.conversation_members cm
    where cm.conversation_id = p_conversation_id
      and cm.profile_id = auth.uid()
  );
$$;


--
-- Name: is_conversation_member(bigint, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_conversation_member(p_conversation_id bigint, p_user_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  select exists (
    select 1
    from conversation_members
    where conversation_id = p_conversation_id
      and profile_id = p_user_id
  );
$$;


--
-- Name: is_current_user_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_current_user_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false)
      or coalesce((auth.jwt() ->> 'role') = 'admin', false)
      or auth.role() = 'service_role';
$$;


--
-- Name: is_pro(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_pro(p_user_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  select exists (
    select 1
    from pro_users
    where user_id = p_user_id
  );
$$;


--
-- Name: moderate_message(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.moderate_message() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_warning_count integer;
begin
  if new.content is not null
     and public.contains_banned_word(new.content)
  then

    insert into public.user_warnings (
      user_id,
      reason
    )
    values (
      new.sender_id,
      'Used banned word'
    );

    select count(*)
    into v_warning_count
    from public.user_warnings
    where user_id = new.sender_id
    AND created_at > CURRENT_DATE - INTERVAL '48 days';

    if v_warning_count >= 3 then
      update public.profiles
      set is_banned = true
      where id = new.sender_id;
    end if;

    raise exception 'MESSAGE_MODERATION_VIOLATION';
  end if;

  return new;
end;
$$;


--
-- Name: post_comment(uuid, bigint, text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.post_comment(p_author_id uuid, p_video_id bigint, p_content text, p_parent_id bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$declare
  new_comment_id bigint;
  v_warning_count integer;
  v_is_now_banned boolean;
begin

  if exists (
    select 1
    from profiles
    where id = auth.uid()
      and is_banned = true
  ) then
    return -5000;
  end if;

  if public.contains_banned_word(p_content) then

    insert into user_warnings (
      user_id,
      reason
    )
    values (
      auth.uid(),
      'Used banned word (' || p_content || ')'
    );

    select count(*)
    into v_warning_count
    from user_warnings
    where user_id = auth.uid();

    v_is_now_banned := v_warning_count >= 3;

    if v_is_now_banned then
      update profiles
      set is_banned = true
      where id = auth.uid();
      return -5000 - v_warning_count;
    end if;

    return -1000 - v_warning_count;
  end if;


  insert into public.comments (author_id, video_id, content, parent_id)
  values (p_author_id, p_video_id, p_content, p_parent_id)
  returning id into new_comment_id;

  update public.videos set comment_count = comment_count + 1 where id = p_video_id;

  if p_parent_id is not null then
    update public.comments set reply_count = reply_count + 1 where id = p_parent_id;
  end if;

  return new_comment_id;
end;$$;


--
-- Name: publish_task_version(bigint, bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.publish_task_version(p_task_id bigint, p_version_id bigint, p_make_current boolean DEFAULT true) RETURNS public.task_versions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_row public.task_versions;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1 from public.tasks t where t.id = p_task_id and t.created_by = v_uid
  ) then
    raise exception 'Only owner can publish versions';
  end if;

  update public.task_versions
  set status = 'published',
      published_at = now()
  where id = p_version_id
    and task_id = p_task_id
  returning * into v_row;

  if not found then
    raise exception 'Version not found';
  end if;

  if p_make_current then
    update public.tasks
    set current_version_id = p_version_id
    where id = p_task_id;
  end if;

  return v_row;
end;
$$;


--
-- Name: quiz_eval_condition(jsonb, jsonb, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.quiz_eval_condition(p_cond jsonb, p_answers jsonb, p_vars jsonb, p_ctx jsonb DEFAULT '{}'::jsonb) RETURNS boolean
    LANGUAGE plpgsql STABLE
    AS $$
declare
  v_op text;
  v_left jsonb;
  v_right jsonb;
  v_num_left numeric;
  v_num_right numeric;
  v_arg jsonb;
  v_list jsonb;
begin
  v_op := lower(coalesce(p_cond->>'op', 'eq'));

  if v_op = 'true' then
    return true;
  elsif v_op = 'false' then
    return false;
  elsif v_op = 'not' then
    return not public.quiz_eval_condition(coalesce(p_cond->'arg', '{"op":"false"}'::jsonb), p_answers, p_vars, p_ctx);
  elsif v_op = 'and' then
    for v_arg in
      select value
      from jsonb_array_elements(case when jsonb_typeof(p_cond->'args') = 'array' then p_cond->'args' else '[]'::jsonb end)
    loop
      if not public.quiz_eval_condition(v_arg, p_answers, p_vars, p_ctx) then
        return false;
      end if;
    end loop;
    return true;
  elsif v_op = 'or' then
    for v_arg in
      select value
      from jsonb_array_elements(case when jsonb_typeof(p_cond->'args') = 'array' then p_cond->'args' else '[]'::jsonb end)
    loop
      if public.quiz_eval_condition(v_arg, p_answers, p_vars, p_ctx) then
        return true;
      end if;
    end loop;
    return false;
  end if;

  v_left := public.quiz_ref_value(p_cond->'left', p_answers, p_vars, p_ctx);
  v_right := public.quiz_ref_value(p_cond->'right', p_answers, p_vars, p_ctx);

  if v_op = 'eq' then
    return v_left = v_right;
  elsif v_op = 'neq' then
    return v_left <> v_right;
  elsif v_op in ('gt', 'gte', 'lt', 'lte') then
    v_num_left := public.quiz_to_numeric(v_left);
    v_num_right := public.quiz_to_numeric(v_right);

    if v_num_left is null or v_num_right is null then
      return false;
    end if;

    if v_op = 'gt' then return v_num_left > v_num_right; end if;
    if v_op = 'gte' then return v_num_left >= v_num_right; end if;
    if v_op = 'lt' then return v_num_left < v_num_right; end if;
    return v_num_left <= v_num_right;
  elsif v_op = 'in' then
    v_list := v_right;
    if jsonb_typeof(v_list) <> 'array' then
      return false;
    end if;
    return exists (
      select 1
      from jsonb_array_elements(v_list) e
      where e.value = v_left
    );
  elsif v_op = 'contains' then
    if jsonb_typeof(v_left) = 'array' then
      return exists (
        select 1
        from jsonb_array_elements(v_left) e
        where e.value = v_right
      );
    elsif jsonb_typeof(v_left) = 'string' then
      return position(coalesce(v_right #>> '{}', '') in coalesce(v_left #>> '{}', '')) > 0;
    else
      return false;
    end if;
  elsif v_op = 'regex' then
    return coalesce(v_left #>> '{}', '') ~ coalesce(v_right #>> '{}', '');
  elsif v_op = 'exists' then
    return v_left is not null and v_left <> 'null'::jsonb;
  end if;

  return false;
end;
$$;


--
-- Name: quiz_logic_is_valid(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.quiz_logic_is_valid(p_logic jsonb) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
  select
    jsonb_typeof(p_logic) = 'object'
    and (
      not (p_logic ? 'rules')
      or jsonb_typeof(p_logic->'rules') = 'array'
    )
    and (
      not (p_logic ? 'pass')
      or jsonb_typeof(p_logic->'pass') = 'object'
    );
$$;


--
-- Name: quiz_ref_value(jsonb, jsonb, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.quiz_ref_value(p_ref jsonb, p_answers jsonb, p_vars jsonb, p_ctx jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    AS $$
declare
  v_source text;
  v_path text;
  v_path_arr text[];
begin
  if p_ref is null then
    return 'null'::jsonb;
  end if;

  if jsonb_typeof(p_ref) <> 'object' then
    return p_ref;
  end if;

  if p_ref ? 'const' then
    return p_ref->'const';
  end if;

  v_source := coalesce(p_ref->>'source', 'answers');
  v_path := coalesce(p_ref->>'path', '');
  v_path_arr := case when v_path = '' then array[]::text[] else string_to_array(v_path, '.') end;

  case v_source
    when 'answers' then return coalesce(p_answers #> v_path_arr, 'null'::jsonb);
    when 'vars' then return coalesce(p_vars #> v_path_arr, 'null'::jsonb);
    when 'ctx' then return coalesce(p_ctx #> v_path_arr, 'null'::jsonb);
    else return 'null'::jsonb;
  end case;
end;
$$;


--
-- Name: quiz_to_numeric(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.quiz_to_numeric(p_val jsonb) RETURNS numeric
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
declare
  v_text text;
begin
  if p_val is null or p_val = 'null'::jsonb then
    return null;
  end if;

  if jsonb_typeof(p_val) = 'number' then
    return (p_val::text)::numeric;
  end if;

  v_text := p_val #>> '{}';
  if v_text is null then
    return null;
  end if;

  if v_text ~ '^-?[0-9]+(\.[0-9]+)?$' then
    return v_text::numeric;
  end if;

  return null;
end;
$_$;


--
-- Name: refresh_conversation_last_message(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_conversation_last_message(p_conversation_id integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$DECLARE
v_last_message text;
v_last_updated_at timestamp;
BEGIN
  SELECT content, created_at
    INTO v_last_message, v_last_updated_at
    FROM messages
    WHERE deleted_at IS NULL
    AND conversation_id = p_conversation_id
    ORDER BY created_at DESC
    LIMIT 1;

  v_last_message := coalesce(v_last_message, '');

  v_last_updated_at := coalesce(
    v_last_updated_at,
    (SELECT updated_at FROM conversations WHERE id = p_conversation_id)
  );

  UPDATE conversations
    SET last_message = v_last_message,
    updated_at = v_last_updated_at
  WHERE id = p_conversation_id;
END;$$;


--
-- Name: refresh_conversation_last_message(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_conversation_last_message(p_conversation_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_last_sender uuid;
  v_last_content text;
begin
  select m.sender_id, m.content
  into v_last_sender, v_last_content
  from public.messages m
  where m.conversation_id = p_conversation_id
    and m.deleted_at is null
  order by m.created_at desc
  limit 1;

  update public.conversations
  set
    updated_at = now(),
    last_message = case
      when v_last_sender is null then ''
      else v_last_sender::text || ': ' || coalesce(v_last_content, '')
    end
  where id = p_conversation_id;
end;
$$;


--
-- Name: request_pro_tier(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.request_pro_tier(key text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$BEGIN
  IF key = '[SECRET_KEY]'
  THEN 
    INSERT INTO pro_users (user_id, created_at) VALUES ((select auth.uid() as uid), now());
    RETURN TRUE;
  END IF;
  RETURN FALSE;
END$$;


--
-- Name: request_streak_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.request_streak_update() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$DECLARE
    v_streak integer;
    v_best_streak integer;
    v_updated_at timestamptz;
    v_has_interaction_today boolean;
BEGIN

    SELECT EXISTS (
        SELECT 1
        FROM user_interactions
        WHERE user_id = auth.uid()
          AND created_at >= CURRENT_DATE
    )
    INTO v_has_interaction_today;

    IF NOT v_has_interaction_today THEN
        RETURN 0;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM user_streaks
        WHERE user_id = auth.uid()
    ) THEN

        INSERT INTO user_streaks (
            user_id,
            streak,
            best_streak,
            updated_at
        )
        VALUES (
            auth.uid(),
            1,
            1,
            now()
        );

        RETURN 1;
    END IF;

    SELECT
        streak,
        best_streak,
        updated_at
    INTO
        v_streak,
        v_best_streak,
        v_updated_at
    FROM user_streaks
    WHERE user_id = auth.uid()
    LIMIT 1;

    IF v_updated_at >= CURRENT_DATE THEN
        RETURN v_streak;
    END IF;

    IF v_updated_at >= CURRENT_DATE - INTERVAL '1 day' THEN
        v_streak := v_streak + 1;
    ELSE
        v_streak := 1;
    END IF;

    v_best_streak := GREATEST(v_best_streak, v_streak);

    UPDATE user_streaks
    SET
        streak = v_streak,
        best_streak = v_best_streak,
        updated_at = now()
    WHERE user_id = auth.uid();

    SELECT
        streak
    INTO
        v_streak
    FROM user_streaks
    WHERE user_id = auth.uid()
    LIMIT 1;

    

    RETURN v_streak;
END;$$;


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    username character varying(30) NOT NULL,
    display_name character varying(50),
    avatar_url text,
    bio character varying(150),
    created_at timestamp with time zone DEFAULT now(),
    followers_count integer DEFAULT 0 NOT NULL,
    following_count integer DEFAULT 0 NOT NULL,
    total_likes_count integer DEFAULT 0 NOT NULL,
    total_videos_count integer DEFAULT 0 NOT NULL,
    is_banned boolean DEFAULT false NOT NULL,
    accepted_eula boolean DEFAULT false NOT NULL,
    accepted_data_processing boolean DEFAULT false NOT NULL,
    onboarding_completed boolean DEFAULT false NOT NULL,
    is_bot boolean DEFAULT false NOT NULL,
    CONSTRAINT profiles_followers_count_check CHECK ((followers_count >= 0)),
    CONSTRAINT profiles_following_count_check CHECK ((following_count >= 0))
);


--
-- Name: COLUMN profiles.followers_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.followers_count IS 'the amount of people that follow this user';


--
-- Name: COLUMN profiles.following_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.following_count IS 'the amount of users this user follows';


--
-- Name: COLUMN profiles.total_likes_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.total_likes_count IS 'the total amount of videos this user has liked';


--
-- Name: COLUMN profiles.total_videos_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.total_videos_count IS 'the total amount of videos this user has published';


--
-- Name: COLUMN profiles.is_banned; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.is_banned IS 'if the user is banned';


--
-- Name: COLUMN profiles.is_bot; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.is_bot IS 'if the user is a bot or a real user';


--
-- Name: search_profiles(text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_profiles(search_query text, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS SETOF public.profiles
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  SELECT p.*
  FROM profiles p
  WHERE
    p.username ILIKE '%' || search_query || '%'
    OR p.display_name ILIKE '%' || search_query || '%'
  ORDER BY
    CASE WHEN LOWER(p.username) = LOWER(search_query) THEN 0 ELSE 1 END,
    CASE WHEN LOWER(p.username) LIKE LOWER(search_query) || '%' THEN 0 ELSE 1 END,
    CASE WHEN LOWER(p.display_name) LIKE LOWER(search_query) || '%' THEN 0 ELSE 1 END,
    p.followers_count DESC,
    p.total_videos_count DESC,
    p.id ASC
  LIMIT p_limit
  OFFSET p_offset;
$$;


--
-- Name: search_videos(text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_videos(search_query text, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS SETOF public.videos
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$SELECT v.*
FROM videos v
WHERE v.is_published = true
  AND (
    v.title ILIKE '%' || search_query || '%'
    OR v.description ILIKE '%' || search_query || '%'
    OR EXISTS (
      SELECT 1
      FROM video_tags vt
      JOIN tags t ON t.id = vt.tag_id
      WHERE vt.video_id = v.id
        AND t.name ILIKE '%' || search_query || '%'
    )
  )
ORDER BY
  CASE WHEN LOWER(v.title) = LOWER(search_query) THEN 0 ELSE 1 END,
  CASE WHEN LOWER(v.title) LIKE LOWER(search_query) || '%' THEN 0 ELSE 1 END,
  v.view_count DESC,
  v.like_count DESC,
  v.created_at DESC
LIMIT p_limit
OFFSET p_offset;$$;


--
-- Name: search_videos_with_author(text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_videos_with_author(search_query text, p_limit integer, p_offset integer) RETURNS TABLE(id bigint, author_id uuid, title text, description text, video_url text, thumbnail_url text, duration_s integer, view_count bigint, like_count bigint, is_published boolean, created_at timestamp with time zone, comment_count integer, profile_id uuid, profile_username text, profile_display_name text, profile_avatar_url text, profile_bio text, profile_created_at timestamp with time zone, profile_followers_count integer, profile_following_count integer, profile_total_likes_count integer, profile_total_videos_count integer, tags text[])
    LANGUAGE sql
    AS $$SELECT
  v.id,
  v.author_id,
  v.title,
  v.description,
  v.video_url,
  v.thumbnail_url,
  v.duration_s,
  v.view_count,
  v.like_count,
  v.is_published,
  v.created_at,
  v.comment_count,

  p.id AS profile_id,
  p.username AS profile_username,
  p.display_name AS profile_display_name,
  p.avatar_url AS profile_avatar_url,
  p.bio AS profile_bio,
  p.created_at AS profile_created_at,
  p.followers_count AS profile_followers_count,
  p.following_count AS profile_following_count,
  p.total_likes_count AS profile_total_likes_count,
  p.total_videos_count AS profile_total_videos_count,

  COALESCE(array_agg(DISTINCT t.name) FILTER (WHERE t.name IS NOT NULL), '{}') AS tags

FROM videos v
JOIN profiles p ON v.author_id = p.id

LEFT JOIN video_tags vt ON vt.video_id = v.id
LEFT JOIN tags t ON t.id = vt.tag_id

WHERE
  v.is_published = true
  AND (
    v.title ILIKE '%' || search_query || '%'
    OR v.description ILIKE '%' || search_query || '%'
    OR EXISTS (
      SELECT 1
      FROM video_tags vt2
      JOIN tags t2 ON t2.id = vt2.tag_id
      WHERE vt2.video_id = v.id
        AND t2.name ILIKE '%' || search_query || '%'
    )
  )

GROUP BY v.id, p.id

ORDER BY
  CASE WHEN LOWER(COALESCE(v.title, '')) = LOWER(COALESCE(search_query, '')) THEN 0 ELSE 1 END,
  CASE WHEN LOWER(COALESCE(v.title, '')) LIKE LOWER(COALESCE(search_query, '')) || '%' THEN 0 ELSE 1 END,
  v.view_count DESC,
  v.like_count DESC,
  v.created_at DESC

LIMIT p_limit
OFFSET p_offset;$$;


--
-- Name: search_videos_with_author(text, integer, integer, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_videos_with_author(search_query text, p_limit integer, p_offset integer, p_show_youtube boolean) RETURNS TABLE(id bigint, author_id uuid, title text, description text, video_url text, thumbnail_url text, duration_s integer, view_count bigint, like_count bigint, is_published boolean, created_at timestamp with time zone, comment_count integer, profile_id uuid, profile_username text, profile_display_name text, profile_avatar_url text, profile_bio text, profile_created_at timestamp with time zone, profile_followers_count integer, profile_following_count integer, profile_total_likes_count integer, profile_total_videos_count integer, tags text[])
    LANGUAGE sql
    AS $$SELECT
  v.id,
  v.author_id,
  v.title,
  v.description,
  v.video_url,
  v.thumbnail_url,
  v.duration_s,
  v.view_count,
  v.like_count,
  v.is_published,
  v.created_at,
  v.comment_count,

  p.id AS profile_id,
  p.username AS profile_username,
  p.display_name AS profile_display_name,
  p.avatar_url AS profile_avatar_url,
  p.bio AS profile_bio,
  p.created_at AS profile_created_at,
  p.followers_count AS profile_followers_count,
  p.following_count AS profile_following_count,
  p.total_likes_count AS profile_total_likes_count,
  p.total_videos_count AS profile_total_videos_count,

  COALESCE(array_agg(DISTINCT t.name) FILTER (WHERE t.name IS NOT NULL), '{}') AS tags

FROM videos v
JOIN profiles p ON v.author_id = p.id

LEFT JOIN video_tags vt ON vt.video_id = v.id
LEFT JOIN tags t ON t.id = vt.tag_id

WHERE
  v.is_published = true
  AND (
    v.title ILIKE '%' || search_query || '%'
    OR v.description ILIKE '%' || search_query || '%'
    OR EXISTS (
      SELECT 1
      FROM video_tags vt2
      JOIN tags t2 ON t2.id = vt2.tag_id
      WHERE vt2.video_id = v.id
        AND t2.name ILIKE '%' || search_query || '%'
    )
  )
  AND is_youtube = (p_show_youtube AND EXISTS(SELECT 1 FROM pro_users pu WHERE pu.user_id = (select auth.uid() as uid)))

GROUP BY v.id, p.id

ORDER BY
  CASE WHEN LOWER(COALESCE(v.title, '')) = LOWER(COALESCE(search_query, '')) THEN 0 ELSE 1 END,
  CASE WHEN LOWER(COALESCE(v.title, '')) LIKE LOWER(COALESCE(search_query, '')) || '%' THEN 0 ELSE 1 END,
  v.view_count DESC,
  v.like_count DESC,
  v.created_at DESC

LIMIT p_limit
OFFSET p_offset;$$;


--
-- Name: search_videos_with_profiles(text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_videos_with_profiles(search_query text, p_limit integer, p_offset integer) RETURNS TABLE(id bigint, author_id uuid, title text, description text, video_url text, thumbnail_url text, duration_ms smallint, view_count smallint, like_count smallint, is_published boolean, created_at timestamp with time zone, comment_count smallint, profile_id uuid, profile_username text, profile_display_name text, profile_avatar_url text, profile_bio text, profile_created_at timestamp with time zone, profile_followers_count integer, profile_following_count integer, profile_total_likes_count integer, profile_total_videos_count integer, tags text[])
    LANGUAGE sql
    AS $$SELECT
  v.id,
  v.author_id,
  v.title,
  v.description,
  v.video_url,
  v.thumbnail_url,
  v.duration_s,
  v.view_count,
  v.like_count,
  v.is_published,
  v.created_at,
  v.comment_count,

  p.id AS profile_id,
  p.username AS profile_username,
  p.display_name AS profile_display_name,
  p.avatar_url AS profile_avatar_url,
  p.bio AS profile_bio,
  p.created_at AS profile_created_at,
  p.followers_count AS profile_followers_count,
  p.following_count AS profile_following_count,
  p.total_likes_count AS profile_total_likes_count,
  p.total_videos_count AS profile_total_videos_count,

  COALESCE(array_agg(DISTINCT t.name) FILTER (WHERE t.name IS NOT NULL), '{}') AS tags

FROM videos v
JOIN profiles p ON v.author_id = p.id

LEFT JOIN video_tags vt ON vt.video_id = v.id
LEFT JOIN tags t ON t.id = vt.tag_id

WHERE
  v.is_published = true
  AND (
    v.title ILIKE '%' || search_query || '%'
    OR v.description ILIKE '%' || search_query || '%'
    OR EXISTS (
      SELECT 1
      FROM video_tags vt2
      JOIN tags t2 ON t2.id = vt2.tag_id
      WHERE vt2.video_id = v.id
        AND t2.name ILIKE '%' || search_query || '%'
    )
  )

GROUP BY v.id, p.id

ORDER BY
  CASE WHEN LOWER(COALESCE(v.title, '')) = LOWER(COALESCE(search_query, '')) THEN 0 ELSE 1 END,
  CASE WHEN LOWER(COALESCE(v.title, '')) LIKE LOWER(COALESCE(search_query, '')) || '%' THEN 0 ELSE 1 END,
  v.view_count DESC,
  v.like_count DESC,
  v.created_at DESC

LIMIT p_limit
OFFSET p_offset;$$;


--
-- Name: send_message(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.send_message(p_conversation_id bigint, p_content text) RETURNS public.messages
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_message public.messages;
begin

  if exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and is_banned = true
  ) then
    raise exception 'USER_BANNED';
  end if;

  if public.contains_banned_word(p_content) then

    insert into public.user_warnings (
      user_id,
      reason
    )
    values (
      auth.uid(),
      'Used banned word'
    );

    raise exception 'MESSAGE_MODERATION_VIOLATION';
  end if;

  insert into public.messages (
    conversation_id,
    sender_id,
    content
  )
  values (
    p_conversation_id,
    auth.uid(),
    p_content
  )
  returning *
  into v_message;

  return v_message;
end;
$$;


--
-- Name: send_message(bigint, text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.send_message(p_conversation_id bigint, p_content text, p_reply_to_message_id bigint) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_message public.messages;
  v_warning_count integer;
  v_is_now_banned boolean;
begin

  if exists (
    select 1
    from profiles
    where id = auth.uid()
      and is_banned = true
  ) then
    return json_build_object(
      'success', false,
      'is_banned', true,
      'error', 'USER_BANNED'
    );
  end if;

  if public.contains_banned_word(p_content) then

    insert into user_warnings (
      user_id,
      reason
    )
    values (
      auth.uid(),
      'Used banned word (' || p_content || ')'
    );

    select count(*)
    into v_warning_count
    from user_warnings
    where user_id = auth.uid();

    v_is_now_banned := v_warning_count >= 3;

    if v_is_now_banned then
      update profiles
      set is_banned = true
      where id = auth.uid();
    end if;

    return json_build_object(
      'success', false,
      'is_banned', v_is_now_banned,
      'error', 'MESSAGE_MODERATION_VIOLATION',
      'warning_count', v_warning_count
    );
  end if;

  insert into public.messages (
    conversation_id,
    sender_id,
    content,
    reply_to_message_id
  )
  values (
    p_conversation_id,
    auth.uid(),
    p_content,
    p_reply_to_message_id
  )
  returning *
  into v_message;

  return json_build_object(
    'success', true,
    'message', row_to_json(v_message)
  );
end;
$$;


--
-- Name: solve_task(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.solve_task(p_task_id bigint, p_answer_data text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_eval jsonb;
begin
  v_eval := public.solve_task_v2(
    p_task_id,
    coalesce(nullif(trim(p_answer_data), ''), '{}')::jsonb,
    null
  );
  return coalesce((v_eval->>'is_correct')::boolean, false);
end;
$$;


--
-- Name: solve_task(jsonb, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.solve_task(p_answer_data jsonb, p_task_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$DECLARE
  is_correct BOOLEAN;
  task_data RECORD;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM task_solutions ts
    WHERE ts.task_id = p_task_id
      AND ts.data = p_answer_data
  )
  INTO is_correct;

  SELECT subjects, xp_reward, xp_punishment
  INTO task_data
  FROM tasks
  WHERE id = p_task_id;

  IF is_correct THEN
    UPDATE profile_levels
    SET level = level + task_data.xp_reward
    WHERE category = ANY(task_data.subjects)
    AND user_id = (select auth.uid() as uid);

    RETURN true;
  ELSE
    UPDATE profile_levels
    SET level = GREATEST(level - task_data.xp_punishment, 0)
    WHERE category = ANY(task_data.subjects)
    AND user_id = (select auth.uid() as uid);
    
    RETURN false;
  END IF;
END;$$;


--
-- Name: solve_task_v2(bigint, jsonb, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.solve_task_v2(p_task_id bigint, p_answer_data jsonb, p_version_id bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_task record;
  v_version_id bigint;
  v_eval jsonb;
  v_is_correct boolean;
  v_xp_factor numeric;
  v_delta double precision;
  v_valid_subjects text[] := array[]::text[];
  v_invalid_subjects text[] := array[]::text[];
  v_subject text;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  select t.id, t.subjects, t.xp_reward, t.xp_punishment, t.current_version_id, t.created_by, t.visibility
  into v_task
  from public.tasks t
  where t.id = p_task_id;

  if not found then
    raise exception 'Task % not found', p_task_id;
  end if;

  v_version_id := coalesce(p_version_id, v_task.current_version_id);
  if v_version_id is null then
    raise exception 'Task % has no current version', p_task_id;
  end if;

  if not exists (
    select 1
    from public.task_versions tv
    where tv.id = v_version_id
      and tv.task_id = p_task_id
      and (tv.status = 'published' or v_task.created_by = v_uid)
  ) then
    raise exception 'Version is not accessible';
  end if;

  v_eval := public.evaluate_task_submission(
    p_task_id,
    v_version_id,
    coalesce(p_answer_data, '{}'::jsonb)
  );

  v_is_correct := coalesce((v_eval->>'is_correct')::boolean, false);
  v_xp_factor := coalesce((v_eval->>'xp_factor')::numeric, 0);

  if v_is_correct then
    v_delta := (v_task.xp_reward * greatest(least(v_xp_factor, 1), 0))::double precision;
  else
    v_delta := (-v_task.xp_punishment)::double precision;
  end if;

  for v_subject in
    select s from unnest(v_task.subjects) as s
  loop
    begin
      insert into public.profile_levels(user_id, category, level)
      values (v_uid, v_subject, 0)
      on conflict (user_id, category) do nothing;

      if not (v_subject = any(v_valid_subjects)) then
        v_valid_subjects := array_append(v_valid_subjects, v_subject);
      end if;
    exception
      when foreign_key_violation then
        if not (v_subject = any(v_invalid_subjects)) then
          v_invalid_subjects := array_append(v_invalid_subjects, v_subject);
        end if;
    end;
  end loop;

  if v_delta >= 0 then
    update public.profile_levels
      set level = level + v_delta
    where user_id = v_uid
      and category = any(v_valid_subjects);
  else
    update public.profile_levels
      set level = greatest(level + v_delta, 0)
    where user_id = v_uid
      and category = any(v_valid_subjects);
  end if;

  insert into public.task_attempts(
    task_id, version_id, user_id, answer_data, evaluation, is_correct, xp_delta
  ) values (
    p_task_id, v_version_id, v_uid, coalesce(p_answer_data, '{}'::jsonb), v_eval, v_is_correct, v_delta
  );

  return v_eval || jsonb_build_object(
    'task_id', p_task_id,
    'version_id', v_version_id,
    'xp_delta', v_delta,
    'applied_subjects', to_jsonb(v_valid_subjects),
    'ignored_subjects', to_jsonb(v_invalid_subjects)
  );
end;
$$;


--
-- Name: sync_quest_connections_latest(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_quest_connections_latest() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$BEGIN
  INSERT INTO public.quest_connections_latest (
    connection_id, is_deleted, type, xp_requirement, last_updated_at, last_updated_by
  )
  VALUES (
    NEW.connection_id,
    COALESCE(NEW.is_deleted, false),
    COALESCE(NEW.type, 'prerequisite'),
    COALESCE(NEW.xp_requirement, 0),
    COALESCE(NEW.created_at,  now()),
    COALESCE(NEW.created_by,  auth.uid())
  )
  ON CONFLICT (connection_id) DO UPDATE SET
    connection_id = COALESCE(NEW.connection_id, quest_connections_latest.connection_id),
    is_deleted = COALESCE(NEW.is_deleted, quest_connections_latest.is_deleted),
    type = COALESCE(NEW.type, quest_connections_latest.type),
    xp_requirement = COALESCE(NEW.xp_requirement, quest_connections_latest.xp_requirement),
    last_updated_at = COALESCE(NEW.created_at, quest_connections_latest.last_updated_at),
    last_updated_by = COALESCE(NEW.created_by, quest_connections_latest.last_updated_by);
  RETURN NEW;
END;$$;


--
-- Name: sync_quests_latest(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_quests_latest() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$BEGIN
  INSERT INTO public.quests_latest (
    quest_id, title, description, difficulty,
    pos_x, pos_y, size_x, size_y,
    color,
    is_deleted, subject, updated_at, version_id
  )
  VALUES (
    NEW.quest_id,
    COALESCE(NEW.title,       ''),
    COALESCE(NEW.description, ''),
    COALESCE(NEW.difficulty,  0.2),
    COALESCE(NEW.pos_x,       0),
    COALESCE(NEW.pos_y,       0),
    COALESCE(NEW.size_x,      200),
    COALESCE(NEW.size_y,      100),
    COALESCE(NEW.color,      0xFFFFFFFF),
    COALESCE(NEW.is_deleted,  false),
    COALESCE(NEW.subject,     ''),
    NEW.created_at,
    NEW.id
  )
  ON CONFLICT (quest_id) DO UPDATE SET
    title       = COALESCE(NEW.title,       quests_latest.title),
    description = COALESCE(NEW.description, quests_latest.description),
    difficulty  = COALESCE(NEW.difficulty,  quests_latest.difficulty),
    pos_x       = COALESCE(NEW.pos_x,       quests_latest.pos_x),
    pos_y       = COALESCE(NEW.pos_y,       quests_latest.pos_y),
    size_x      = COALESCE(NEW.size_x,      quests_latest.size_x),
    size_y      = COALESCE(NEW.size_y,      quests_latest.size_y),
    color       = COALESCE(NEW.color,       quests_latest.color),
    is_deleted  = COALESCE(NEW.is_deleted,  quests_latest.is_deleted),
    subject     = COALESCE(NEW.subject,     quests_latest.subject),
    updated_at  = NEW.created_at,
    version_id  = NEW.id;

  RETURN NEW;
END;$$;


--
-- Name: toggle_dislike(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.toggle_dislike(p_video_id bigint) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$declare
  already_disliked boolean;
  p_user_id uuid;
begin
  p_user_id = auth.uid();
  select exists(select 1 from public.dislikes where user_id = p_user_id and video_id = p_video_id) into already_disliked;

  if already_disliked then
    delete from public.dislikes where user_id = p_user_id and video_id = p_video_id;
    return 'undisliked';
  else
    delete from public.likes where user_id = p_user_id and video_id = p_video_id;
    update public.videos set like_count = greatest(like_count - 1, 0) where id = p_video_id;
    insert into public.dislikes (user_id, video_id) values (p_user_id, p_video_id);
    return 'disliked';
  end if;
end;$$;


--
-- Name: toggle_dislike(uuid, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.toggle_dislike(p_user_id uuid, p_video_id bigint) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$declare
  already_disliked boolean;
begin
  select exists(select 1 from public.dislikes where user_id = p_user_id and video_id = p_video_id) into already_disliked;

  if already_disliked then
    delete from public.dislikes where user_id = p_user_id and video_id = p_video_id;
    return 'undisliked';
  else
    delete from public.likes where user_id = p_user_id and video_id = p_video_id;
    update public.videos set like_count = greatest(like_count - 1, 0) where id = p_video_id;
    insert into public.dislikes (user_id, video_id) values (p_user_id, p_video_id);
    return 'disliked';
  end if;
end;$$;


--
-- Name: toggle_follow(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.toggle_follow(p_other_id uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$declare
  already_followed boolean;
  p_user_id uuid;
begin
  p_user_id = auth.uid();
  if p_user_id = p_other_id then
    raise exception 'cannot follow yourself';
  end if;

  perform 1 from public.profiles where id = p_other_id;
  if not found then
    raise exception 'target profile not found';
  end if;

  select exists(
    select 1 from public.follows
    where follower_id = p_user_id and following_id = p_other_id
  ) into already_followed;

  if already_followed then
    delete from public.follows
      where follower_id = p_user_id and following_id = p_other_id;
      
    update public.profiles
      set followers_count = greatest(followers_count - 1, 0)
      where id = p_other_id;

    update public.profiles
      set following_count = greatest(following_count - 1, 0)
      where id = p_user_id;
    return 'unfollowed';
  else
    insert into public.follows(follower_id, following_id, created_at)
      values (p_user_id, p_other_id, now());

    update public.profiles
      set followers_count = followers_count + 1
      where id = p_other_id;

    update public.profiles
      set following_count = following_count + 1
      where id = p_user_id;
    return 'followed';
  end if;
end;$$;


--
-- Name: toggle_like(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.toggle_like(p_video_id bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$declare
  already_liked boolean;
  author_id uuid;
  p_user_id uuid;
begin
  p_user_id = auth.uid();
  select exists(select 1 from public.likes where user_id = p_user_id and video_id = p_video_id) into already_liked;

  select (select v.author_id from public.videos v where v.id = p_video_id) into author_id;

  if already_liked then
    delete from public.likes where user_id = p_user_id and video_id = p_video_id;
    update public.videos set like_count = greatest(like_count - 1, 0) where id = p_video_id;
    update public.profiles set total_likes_count = greatest(total_likes_count - 1, 0) where id = author_id;
    return 'unliked';
  else
    delete from public.dislikes where user_id = p_user_id and video_id = p_video_id;
    insert into public.likes (user_id, video_id) values (p_user_id, p_video_id);
    update public.videos set like_count = like_count + 1 where id = p_video_id;
    update public.profiles set total_likes_count = total_likes_count + 1 where id = author_id;
    return 'liked';
  end if;
end;$$;


--
-- Name: toggle_like(uuid, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.toggle_like(p_user_id uuid, p_video_id bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$declare
  already_liked boolean;
  author_id uuid;
begin
  select exists(select 1 from public.likes where user_id = p_user_id and video_id = p_video_id) into already_liked;

  select (select v.author_id from public.videos v where v.id = p_video_id) into author_id;

  if already_liked then
    delete from public.likes where user_id = p_user_id and video_id = p_video_id;
    update public.videos set like_count = greatest(like_count - 1, 0) where id = p_video_id;
    update public.profiles set total_likes_count = greatest(total_likes_count - 1, 0) where id = author_id;
    return 'unliked';
  else
    delete from public.dislikes where user_id = p_user_id and video_id = p_video_id;
    insert into public.likes (user_id, video_id) values (p_user_id, p_video_id);
    update public.videos set like_count = like_count + 1 where id = p_video_id;
    update public.profiles set total_likes_count = total_likes_count + 1 where id = author_id;
    return 'liked';
  end if;
end;$$;


--
-- Name: toggle_like_comment(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.toggle_like_comment(p_comment_id integer) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
  v_user_id uuid := get_my_jwt_sub();
  v_now timestamptz := now();
  v_did_like boolean;
BEGIN
  IF EXISTS (SELECT 1 FROM comment_likes cl WHERE cl.user_id = v_user_id AND cl.comment_id = p_comment_id) THEN
    DELETE FROM comment_likes
     WHERE user_id = v_user_id AND comment_id = p_comment_id;

    UPDATE comments
      SET like_count = GREATEST(like_count - 1, 0)
    WHERE id = p_comment_id;

    v_did_like := false;
  ELSE
    INSERT INTO comment_likes(user_id, comment_id, created_at)
    VALUES (v_user_id, p_comment_id, v_now);

    UPDATE comments
      SET like_count = like_count + 1
    WHERE id = p_comment_id;

    v_did_like := true;
  END IF;

  RETURN v_did_like;
END;$$;


--
-- Name: toggle_like_old(text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.toggle_like_old(p_user_id text, p_video_id bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$declare
  already_liked boolean;
  author_id text;
begin
  select exists(select 1 from public.likes where user_id = p_user_id and video_id = p_video_id) into already_liked;

  select (select v.author_id from public.videos v where v.id = p_video_id) into author_id;

  if already_liked then
    delete from public.likes where user_id = p_user_id and video_id = p_video_id;
    update public.videos set like_count = greatest(like_count - 1, 0) where id = p_video_id;
    update public.profiles set total_likes_count = greatest(total_likes_count - 1, 0) where id = author_id;
    return 'unliked';
  else
    delete from public.dislikes where user_id = p_user_id and video_id = p_video_id;
    insert into public.likes (user_id, video_id) values (p_user_id, p_video_id);
    update public.videos set like_count = like_count + 1 where id = p_video_id;
    update public.profiles set total_likes_count = total_likes_count + 1 where id = author_id;
    return 'liked';
  end if;
end;$$;


--
-- Name: toggle_theme_like(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.toggle_theme_like(p_theme_id uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$declare
  v_already_liked boolean;
  v_user_id uuid;

begin
  v_user_id = auth.uid();
  select exists(select 1 from public.theme_likes where user_id = v_user_id and theme_id = p_theme_id) into v_already_liked;


  if v_already_liked then
    delete from public.theme_likes where user_id = v_user_id and theme_id = p_theme_id;
    update public.themes set likes_count = greatest(likes_count - 1, 0) where id = p_theme_id;
    return false;
  else
    insert into public.theme_likes (user_id, theme_id) values (v_user_id, p_theme_id);
    update public.themes set likes_count = likes_count + 1 where id = p_theme_id;
    return true;
  end if;
end;$$;


--
-- Name: track_message_versions(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.track_message_versions() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$declare
  v_next_version integer;
begin
  if tg_op = 'INSERT' then
    insert into public.message_versions (
      message_id,
      conversation_id,
      version_no,
      content,
      edited_at,
      edited_by,
      change_type
    )
    values (
      new.id,
      new.conversation_id,
      1,
      coalesce(new.content, ''),
      coalesce(new.created_at, now()),
      new.sender_id,
      'initial'
    )
    on conflict do nothing;

    perform public.refresh_conversation_last_message(new.conversation_id);
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.content is distinct from old.content then
      select coalesce(max(version_no), 0) + 1
      into v_next_version
      from public.message_versions
      where message_id = new.id;

      insert into public.message_versions (
        message_id,
        conversation_id,
        version_no,
        content,
        edited_at,
        edited_by,
        change_type
      )
      values (
        new.id,
        new.conversation_id,
        v_next_version,
        coalesce(new.content, ''),
        coalesce(new.edited_at, now()),
        auth.uid(),
        'edit'
      );
    end if;

    if new.deleted_at is distinct from old.deleted_at and new.deleted_at is not null then
      select coalesce(max(version_no), 0) + 1
      into v_next_version
      from public.message_versions
      where message_id = new.id;

      insert into public.message_versions (
        message_id,
        conversation_id,
        version_no,
        content,
        edited_at,
        edited_by,
        change_type
      )
      values (
        new.id,
        new.conversation_id,
        v_next_version,
        coalesce(new.content, ''),
        new.deleted_at,
        auth.uid(),
        'delete'
      );
    end if;

    perform public.refresh_conversation_last_message(new.conversation_id);
    return new;
  end if;

  return new;
end;$$;


--
-- Name: trg_inc_profile_video_count(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_inc_profile_video_count() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE profiles
  SET total_videos_count = total_videos_count + 1
  WHERE id = NEW.author_id;

  RETURN NEW;
END;
$$;


--
-- Name: unseen_video_tags(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.unseen_video_tags(p_user_id uuid) RETURNS SETOF public.video_tags
    LANGUAGE sql STABLE
    AS $$
  SELECT vt.*
  FROM video_tags vt
  WHERE NOT EXISTS (
    SELECT 1
    FROM user_interactions ui
    WHERE ui.video_id = vt.video_id
      AND ui.user_id = p_user_id
  );
$$;


--
-- Name: ai_bots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_bots (
    user_id uuid NOT NULL,
    system_prompt text DEFAULT 'You are a helpful assistant for educational purposes'::text NOT NULL
);


--
-- Name: applied_themes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.applied_themes (
    user_id uuid DEFAULT auth.uid() NOT NULL,
    theme_id uuid DEFAULT gen_random_uuid() NOT NULL
);


--
-- Name: TABLE applied_themes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.applied_themes IS 'the theme every user currently has applied';


--
-- Name: ban_appeals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ban_appeals (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    appeal_message text NOT NULL,
    approved boolean,
    answer text,
    reviewer_id uuid
);


--
-- Name: ban_appeals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ban_appeals ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.ban_appeals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: banned_words; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.banned_words (
    word text NOT NULL,
    id bigint NOT NULL,
    severity smallint DEFAULT '1'::smallint NOT NULL,
    CONSTRAINT banned_words_severity_check CHECK ((severity > 0))
);


--
-- Name: banned_words_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.banned_words ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.banned_words_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categories (
    id text NOT NULL,
    name text NOT NULL,
    description text
);


--
-- Name: TABLE categories; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.categories IS 'categories you can level up in';


--
-- Name: comment_likes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comment_likes (
    user_id uuid NOT NULL,
    comment_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE comment_likes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.comment_likes IS 'likes of comments';


--
-- Name: comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comments (
    id bigint NOT NULL,
    author_id uuid NOT NULL,
    video_id bigint NOT NULL,
    content character varying(300) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    parent_id bigint,
    reply_count integer DEFAULT 0 NOT NULL,
    like_count integer DEFAULT 0 NOT NULL
);


--
-- Name: TABLE comments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.comments IS 'all comments of all videos and users';


--
-- Name: comments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.comments ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.comments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: conversation_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversation_members (
    conversation_id bigint NOT NULL,
    profile_id uuid NOT NULL,
    role text DEFAULT 'member'::text NOT NULL,
    joined_at timestamp with time zone DEFAULT now() NOT NULL,
    last_read_message_id bigint
);


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversations (
    id bigint NOT NULL,
    type text NOT NULL,
    created_by uuid NOT NULL,
    title text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_message text DEFAULT ''::text NOT NULL,
    CONSTRAINT conversations_type_check CHECK ((type = ANY (ARRAY['direct'::text, 'group'::text, 'direct-ai'::text])))
);


--
-- Name: COLUMN conversations.last_message; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.conversations.last_message IS 'the last message sent by a member of that conversation';


--
-- Name: conversations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversations_id_seq OWNED BY public.conversations.id;


--
-- Name: dislikes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dislikes (
    user_id uuid NOT NULL,
    video_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE dislikes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.dislikes IS 'all dislikes of all users';


--
-- Name: follows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.follows (
    follower_id uuid NOT NULL,
    following_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: likes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.likes (
    user_id uuid NOT NULL,
    video_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: message_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.message_versions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.message_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.messages ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: pro_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pro_users (
    user_id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: profile_levels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profile_levels (
    user_id uuid DEFAULT auth.uid() NOT NULL,
    category text DEFAULT ''::text NOT NULL,
    level real DEFAULT '0'::real NOT NULL
);


--
-- Name: TABLE profile_levels; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.profile_levels IS 'the different levels in each category of every profile';


--
-- Name: COLUMN profile_levels.level; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profile_levels.level IS 'the level the user is in that category';


--
-- Name: profile_quest_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profile_quest_progress (
    user_id uuid DEFAULT gen_random_uuid() NOT NULL,
    quest_id bigint NOT NULL,
    progress real DEFAULT '0'::real NOT NULL
);


--
-- Name: profile_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profile_settings (
    user_id uuid DEFAULT gen_random_uuid() NOT NULL,
    setting_key text NOT NULL,
    setting_value text NOT NULL
);


--
-- Name: quest_connection_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quest_connection_versions (
    id bigint NOT NULL,
    connection_id bigint NOT NULL,
    type text DEFAULT 'prerequisite'::text,
    is_deleted boolean DEFAULT false NOT NULL,
    update_message text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid NOT NULL,
    xp_requirement real
);


--
-- Name: quest_connection_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.quest_connection_versions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.quest_connection_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: quest_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quest_connections (
    from_id bigint NOT NULL,
    to_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid NOT NULL,
    connection_id bigint NOT NULL
);


--
-- Name: quest_connections_connection_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.quest_connections ALTER COLUMN connection_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.quest_connections_connection_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: quest_connections_latest; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quest_connections_latest (
    last_updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_updated_by uuid NOT NULL,
    connection_id bigint NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL,
    type text DEFAULT ''::text NOT NULL,
    xp_requirement real DEFAULT '0'::real NOT NULL
);


--
-- Name: TABLE quest_connections_latest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.quest_connections_latest IS 'This is a duplicate of quest_connections';


--
-- Name: quest_connections_latest_connection_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.quest_connections_latest ALTER COLUMN connection_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.quest_connections_latest_connection_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: quest_title_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quest_title_aliases (
    quest_id bigint NOT NULL,
    alias text NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: quest_title_aliases_quest_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.quest_title_aliases ALTER COLUMN quest_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.quest_title_aliases_quest_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: quest_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quest_versions (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    quest_id bigint NOT NULL,
    update_message text DEFAULT ''::text NOT NULL,
    title text,
    description text,
    difficulty real,
    pos_x bigint,
    pos_y bigint,
    size_x smallint,
    size_y smallint,
    is_deleted boolean,
    subject text,
    color bigint
);


--
-- Name: quest_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.quest_versions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.quest_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: quests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quests (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid NOT NULL
);


--
-- Name: TABLE quests; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.quests IS 'all quests ever written, the outdated ones aswell';


--
-- Name: quests_latest; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quests_latest (
    quest_id bigint NOT NULL,
    title text DEFAULT ''::text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    difficulty real DEFAULT 0.2 NOT NULL,
    pos_x bigint DEFAULT 0 NOT NULL,
    pos_y bigint DEFAULT 0 NOT NULL,
    size_x smallint DEFAULT 200 NOT NULL,
    size_y smallint DEFAULT 100 NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL,
    subject text DEFAULT ''::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    version_id bigint,
    color bigint DEFAULT '4294967295'::bigint NOT NULL
);


--
-- Name: saved_themes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.saved_themes (
    user_id uuid DEFAULT auth.uid() NOT NULL,
    theme_id uuid NOT NULL
);


--
-- Name: saved_videos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.saved_videos (
    user_id uuid NOT NULL,
    video_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tags (
    id integer NOT NULL,
    name character varying(30) NOT NULL
);


--
-- Name: tags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tags ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.tags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: task_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_attempts (
    id bigint NOT NULL,
    task_id bigint NOT NULL,
    version_id bigint NOT NULL,
    user_id uuid DEFAULT auth.uid() NOT NULL,
    answer_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    evaluation jsonb DEFAULT '{}'::jsonb NOT NULL,
    is_correct boolean DEFAULT false NOT NULL,
    xp_delta double precision DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT task_attempts_answer_data_check CHECK ((jsonb_typeof(answer_data) = 'object'::text)),
    CONSTRAINT task_attempts_evaluation_check CHECK ((jsonb_typeof(evaluation) = 'object'::text))
);


--
-- Name: task_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.task_attempts ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.task_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: task_solutions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_solutions (
    solution_id bigint NOT NULL,
    task_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT gen_random_uuid() NOT NULL,
    data jsonb NOT NULL
);


--
-- Name: task_solutions_solution_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.task_solutions ALTER COLUMN solution_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.task_solutions_solution_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: task_solves; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_solves (
    user_id uuid DEFAULT auth.uid() NOT NULL,
    task_id bigint NOT NULL,
    solved_at timestamp with time zone NOT NULL,
    id bigint NOT NULL
);


--
-- Name: task_solves_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.task_solves ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.task_solves_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: task_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.task_versions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.task_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tasks (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    title text DEFAULT 'No Title Provided'::text,
    type text NOT NULL,
    data jsonb NOT NULL,
    subjects text[] DEFAULT '{General}'::text[] NOT NULL,
    xp_reward double precision DEFAULT '0.1'::double precision NOT NULL,
    xp_punishment double precision DEFAULT '0'::double precision NOT NULL,
    visibility text DEFAULT 'public'::text NOT NULL,
    current_version_id bigint,
    CONSTRAINT tasks_visibility_check CHECK ((visibility = ANY (ARRAY['private'::text, 'unlisted'::text, 'public'::text])))
);


--
-- Name: COLUMN tasks.xp_punishment; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tasks.xp_punishment IS 'the xp the user gets punished for not getting the correct answer';


--
-- Name: tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tasks ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.tasks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: theme_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.theme_comments (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    theme_id uuid,
    user_id uuid,
    comment_text text NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: theme_likes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.theme_likes (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    theme_id uuid,
    user_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: themes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.themes (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    created_by uuid,
    name text NOT NULL,
    primary_color bigint NOT NULL,
    is_public boolean DEFAULT false,
    likes_count integer DEFAULT 0,
    theme_data text,
    original_theme_id uuid
);


--
-- Name: COLUMN themes.original_theme_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.themes.original_theme_id IS 'if this theme is a copy of a theme by someone else, this is the id of the original theme';


--
-- Name: user_interactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_interactions (
    user_id uuid DEFAULT gen_random_uuid() NOT NULL,
    video_id bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    interaction_type text DEFAULT ''::text NOT NULL,
    additional_data jsonb,
    interaction_id uuid DEFAULT gen_random_uuid() NOT NULL,
    liked boolean DEFAULT false NOT NULL,
    watch_time double precision DEFAULT '0'::double precision
);


--
-- Name: COLUMN user_interactions.additional_data; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.user_interactions.additional_data IS 'any additional data like if the video was liked, the engagement rate, etc.';


--
-- Name: user_streaks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_streaks (
    user_id uuid DEFAULT gen_random_uuid() NOT NULL,
    streak integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    best_streak integer
);


--
-- Name: user_warnings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_warnings (
    id bigint NOT NULL,
    user_id uuid NOT NULL,
    reason text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    forgiven boolean DEFAULT false NOT NULL
);


--
-- Name: user_warnings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.user_warnings ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.user_warnings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: video_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.video_reports (
    id bigint NOT NULL,
    user_id uuid NOT NULL,
    video_id bigint NOT NULL,
    reason text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: video_reports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.video_reports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: video_reports_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.video_reports_id_seq OWNED BY public.video_reports.id;


--
-- Name: videos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.videos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.videos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: conversations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations ALTER COLUMN id SET DEFAULT nextval('public.conversations_id_seq'::regclass);


--
-- Name: video_reports id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_reports ALTER COLUMN id SET DEFAULT nextval('public.video_reports_id_seq'::regclass);


--
-- Name: ai_bots ai_bots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_bots
    ADD CONSTRAINT ai_bots_pkey PRIMARY KEY (user_id);


--
-- Name: applied_themes apllied_themes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applied_themes
    ADD CONSTRAINT apllied_themes_pkey PRIMARY KEY (user_id);


--
-- Name: ban_appeals ban_appeals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ban_appeals
    ADD CONSTRAINT ban_appeals_pkey PRIMARY KEY (id);


--
-- Name: banned_words banned_words_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.banned_words
    ADD CONSTRAINT banned_words_pkey PRIMARY KEY (id);


--
-- Name: banned_words banned_words_word_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.banned_words
    ADD CONSTRAINT banned_words_word_key UNIQUE (word);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- Name: comment_likes comment_likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment_likes
    ADD CONSTRAINT comment_likes_pkey PRIMARY KEY (user_id, comment_id);


--
-- Name: comments comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_pkey PRIMARY KEY (id);


--
-- Name: conversation_members conversation_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_members
    ADD CONSTRAINT conversation_members_pkey PRIMARY KEY (conversation_id, profile_id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: dislikes dislikes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dislikes
    ADD CONSTRAINT dislikes_pkey PRIMARY KEY (user_id, video_id);


--
-- Name: follows follows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_pkey PRIMARY KEY (follower_id, following_id);


--
-- Name: likes likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.likes
    ADD CONSTRAINT likes_pkey PRIMARY KEY (user_id, video_id);


--
-- Name: message_versions message_versions_message_id_version_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_versions
    ADD CONSTRAINT message_versions_message_id_version_no_key UNIQUE (message_id, version_no);


--
-- Name: message_versions message_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_versions
    ADD CONSTRAINT message_versions_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: pro_users pro_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pro_users
    ADD CONSTRAINT pro_users_pkey PRIMARY KEY (user_id);


--
-- Name: profile_levels profile_levels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_levels
    ADD CONSTRAINT profile_levels_pkey PRIMARY KEY (user_id, category);


--
-- Name: profile_quest_progress profile_quest_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_quest_progress
    ADD CONSTRAINT profile_quest_progress_pkey PRIMARY KEY (user_id, quest_id);


--
-- Name: profile_settings profile_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_settings
    ADD CONSTRAINT profile_settings_pkey PRIMARY KEY (user_id, setting_key);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_username_key UNIQUE (username);


--
-- Name: quest_connection_versions quest_connection_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_connection_versions
    ADD CONSTRAINT quest_connection_versions_pkey PRIMARY KEY (id);


--
-- Name: quest_connections_latest quest_connections_latest_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_connections_latest
    ADD CONSTRAINT quest_connections_latest_pkey PRIMARY KEY (connection_id);


--
-- Name: quest_connections quest_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_connections
    ADD CONSTRAINT quest_connections_pkey PRIMARY KEY (connection_id);


--
-- Name: quest_title_aliases quest_title_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_title_aliases
    ADD CONSTRAINT quest_title_aliases_pkey PRIMARY KEY (quest_id, alias);


--
-- Name: quest_versions quest_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_versions
    ADD CONSTRAINT quest_versions_pkey PRIMARY KEY (id);


--
-- Name: quests quests_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quests
    ADD CONSTRAINT quests_id_key UNIQUE (id);


--
-- Name: quests_latest quests_latest_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quests_latest
    ADD CONSTRAINT quests_latest_pkey PRIMARY KEY (quest_id);


--
-- Name: quests quests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quests
    ADD CONSTRAINT quests_pkey PRIMARY KEY (id);


--
-- Name: saved_themes saved_themes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_themes
    ADD CONSTRAINT saved_themes_pkey PRIMARY KEY (user_id, theme_id);


--
-- Name: saved_videos saved_videos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_videos
    ADD CONSTRAINT saved_videos_pkey PRIMARY KEY (user_id, video_id);


--
-- Name: tags tags_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_name_key UNIQUE (name);


--
-- Name: tags tags_name_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_name_unique UNIQUE (name);


--
-- Name: tags tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (id);


--
-- Name: task_attempts task_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_attempts
    ADD CONSTRAINT task_attempts_pkey PRIMARY KEY (id);


--
-- Name: task_solutions task_solutions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_solutions
    ADD CONSTRAINT task_solutions_pkey PRIMARY KEY (solution_id);


--
-- Name: task_solves task_solves_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_solves
    ADD CONSTRAINT task_solves_pkey PRIMARY KEY (id);


--
-- Name: task_versions task_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_versions
    ADD CONSTRAINT task_versions_pkey PRIMARY KEY (id);


--
-- Name: task_versions task_versions_task_id_version_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_versions
    ADD CONSTRAINT task_versions_task_id_version_no_key UNIQUE (task_id, version_no);


--
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);


--
-- Name: theme_comments theme_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_comments
    ADD CONSTRAINT theme_comments_pkey PRIMARY KEY (id);


--
-- Name: theme_likes theme_likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_likes
    ADD CONSTRAINT theme_likes_pkey PRIMARY KEY (id);


--
-- Name: theme_likes theme_likes_theme_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_likes
    ADD CONSTRAINT theme_likes_theme_id_user_id_key UNIQUE (theme_id, user_id);


--
-- Name: themes themes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.themes
    ADD CONSTRAINT themes_pkey PRIMARY KEY (id);


--
-- Name: user_interactions user_interactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_interactions
    ADD CONSTRAINT user_interactions_pkey PRIMARY KEY (interaction_id);


--
-- Name: user_streaks user_streaks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_streaks
    ADD CONSTRAINT user_streaks_pkey PRIMARY KEY (user_id);


--
-- Name: user_warnings user_warnings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_warnings
    ADD CONSTRAINT user_warnings_pkey PRIMARY KEY (id);


--
-- Name: video_reports video_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_reports
    ADD CONSTRAINT video_reports_pkey PRIMARY KEY (id);


--
-- Name: video_tags video_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_tags
    ADD CONSTRAINT video_tags_pkey PRIMARY KEY (video_id, tag_id);


--
-- Name: video_tags video_tags_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_tags
    ADD CONSTRAINT video_tags_unique UNIQUE (video_id, tag_id);


--
-- Name: videos videos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.videos
    ADD CONSTRAINT videos_pkey PRIMARY KEY (id);


--
-- Name: comments_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX comments_id_idx ON public.comments USING btree (id);


--
-- Name: idx_message_versions_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_message_versions_conversation_id ON public.message_versions USING btree (conversation_id);


--
-- Name: idx_message_versions_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_message_versions_message_id ON public.message_versions USING btree (message_id, version_no DESC);


--
-- Name: idx_task_attempts_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_attempts_created_at ON public.task_attempts USING btree (created_at);


--
-- Name: idx_task_attempts_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_attempts_task_id ON public.task_attempts USING btree (task_id);


--
-- Name: idx_task_attempts_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_attempts_user_id ON public.task_attempts USING btree (user_id);


--
-- Name: idx_task_versions_logic_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_versions_logic_gin ON public.task_versions USING gin (logic);


--
-- Name: idx_task_versions_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_versions_status ON public.task_versions USING btree (status);


--
-- Name: idx_task_versions_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_versions_task_id ON public.task_versions USING btree (task_id);


--
-- Name: idx_task_versions_ui_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_versions_ui_gin ON public.task_versions USING gin (ui);


--
-- Name: idx_tasks_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_created_by ON public.tasks USING btree (created_by);


--
-- Name: idx_tasks_visibility; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_visibility ON public.tasks USING btree (visibility);


--
-- Name: messages_conversation_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_conversation_created_at_idx ON public.messages USING btree (conversation_id, created_at);


--
-- Name: profile_levels_user_category_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX profile_levels_user_category_uq ON public.profile_levels USING btree (user_id, category);


--
-- Name: profiles_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profiles_created_at_idx ON public.profiles USING btree (created_at);


--
-- Name: user_interactions_video_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_interactions_video_id_idx ON public.user_interactions USING btree (video_id);


--
-- Name: videos_comment_count_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX videos_comment_count_idx ON public.videos USING btree (comment_count);


--
-- Name: videos_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX videos_created_at_idx ON public.videos USING btree (created_at);


--
-- Name: videos_fts_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX videos_fts_idx ON public.videos USING gin (fts);


--
-- Name: quest_connection_versions on_quest_connection_version_inserted; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER on_quest_connection_version_inserted AFTER INSERT ON public.quest_connection_versions FOR EACH ROW EXECUTE FUNCTION public.sync_quest_connections_latest();


--
-- Name: quest_versions on_quest_version_inserted; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER on_quest_version_inserted AFTER INSERT ON public.quest_versions FOR EACH ROW EXECUTE FUNCTION public.sync_quests_latest();


--
-- Name: messages trg_track_message_versions; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_track_message_versions AFTER INSERT OR UPDATE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.track_message_versions();


--
-- Name: videos videos_after_insert_inc_count; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER videos_after_insert_inc_count AFTER INSERT ON public.videos FOR EACH ROW EXECUTE FUNCTION public.trg_inc_profile_video_count();


--
-- Name: ai_bots ai_bots_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_bots
    ADD CONSTRAINT ai_bots_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: applied_themes apllied_themes_theme_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applied_themes
    ADD CONSTRAINT apllied_themes_theme_id_fkey FOREIGN KEY (theme_id) REFERENCES public.themes(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: applied_themes apllied_themes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applied_themes
    ADD CONSTRAINT apllied_themes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: ban_appeals ban_appeals_reviewer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ban_appeals
    ADD CONSTRAINT ban_appeals_reviewer_id_fkey FOREIGN KEY (reviewer_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: ban_appeals ban_appeals_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ban_appeals
    ADD CONSTRAINT ban_appeals_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment_likes comment_likes_comment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment_likes
    ADD CONSTRAINT comment_likes_comment_id_fkey FOREIGN KEY (comment_id) REFERENCES public.comments(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comment_likes comment_likes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comment_likes
    ADD CONSTRAINT comment_likes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comments comments_author_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_author_id_fkey FOREIGN KEY (author_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: comments comments_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.comments(id) ON DELETE CASCADE;


--
-- Name: comments comments_video_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_video_id_fkey FOREIGN KEY (video_id) REFERENCES public.videos(id) ON DELETE CASCADE;


--
-- Name: conversation_members conversation_members_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_members
    ADD CONSTRAINT conversation_members_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: conversation_members conversation_members_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_members
    ADD CONSTRAINT conversation_members_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: conversations conversations_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: dislikes dislikes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dislikes
    ADD CONSTRAINT dislikes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id);


--
-- Name: dislikes dislikes_video_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dislikes
    ADD CONSTRAINT dislikes_video_id_fkey FOREIGN KEY (video_id) REFERENCES public.videos(id) ON DELETE CASCADE;


--
-- Name: follows follows_follower_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_follower_id_fkey FOREIGN KEY (follower_id) REFERENCES public.profiles(id);


--
-- Name: follows follows_following_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_following_id_fkey FOREIGN KEY (following_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: likes likes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.likes
    ADD CONSTRAINT likes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: likes likes_video_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.likes
    ADD CONSTRAINT likes_video_id_fkey FOREIGN KEY (video_id) REFERENCES public.videos(id) ON DELETE CASCADE;


--
-- Name: message_versions message_versions_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_versions
    ADD CONSTRAINT message_versions_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: message_versions message_versions_edited_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_versions
    ADD CONSTRAINT message_versions_edited_by_fkey FOREIGN KEY (edited_by) REFERENCES public.profiles(id);


--
-- Name: message_versions message_versions_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_versions
    ADD CONSTRAINT message_versions_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: messages messages_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: messages messages_reply_to_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_reply_to_message_id_fkey FOREIGN KEY (reply_to_message_id) REFERENCES public.messages(id) ON DELETE SET NULL;


--
-- Name: messages messages_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: pro_users pro_users_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pro_users
    ADD CONSTRAINT pro_users_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: profile_levels profile_levels_category_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_levels
    ADD CONSTRAINT profile_levels_category_fkey FOREIGN KEY (category) REFERENCES public.categories(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: profile_levels profile_levels_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_levels
    ADD CONSTRAINT profile_levels_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: profile_quest_progress profile_quest_progress_quest_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_quest_progress
    ADD CONSTRAINT profile_quest_progress_quest_id_fkey FOREIGN KEY (quest_id) REFERENCES public.quests(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: profile_quest_progress profile_quest_progress_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_quest_progress
    ADD CONSTRAINT profile_quest_progress_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: profile_settings profile_settings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profile_settings
    ADD CONSTRAINT profile_settings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quest_connection_versions quest_connection_versions_connection_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_connection_versions
    ADD CONSTRAINT quest_connection_versions_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES public.quest_connections(connection_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quest_connection_versions quest_connection_versions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_connection_versions
    ADD CONSTRAINT quest_connection_versions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quest_connection_versions quest_connection_versions_created_by_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_connection_versions
    ADD CONSTRAINT quest_connection_versions_created_by_fkey1 FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quest_connections quest_connections_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_connections
    ADD CONSTRAINT quest_connections_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quest_connections quest_connections_from_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_connections
    ADD CONSTRAINT quest_connections_from_id_fkey FOREIGN KEY (from_id) REFERENCES public.quests(id) ON DELETE CASCADE;


--
-- Name: quest_connections_latest quest_connections_latest_connection_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_connections_latest
    ADD CONSTRAINT quest_connections_latest_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES public.quest_connections(connection_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quest_connections_latest quest_connections_latest_last_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_connections_latest
    ADD CONSTRAINT quest_connections_latest_last_updated_by_fkey FOREIGN KEY (last_updated_by) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quest_connections quest_connections_to_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_connections
    ADD CONSTRAINT quest_connections_to_id_fkey FOREIGN KEY (to_id) REFERENCES public.quests(id) ON DELETE CASCADE;


--
-- Name: quest_title_aliases quest_title_aliases_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_title_aliases
    ADD CONSTRAINT quest_title_aliases_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quest_title_aliases quest_title_aliases_quest_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_title_aliases
    ADD CONSTRAINT quest_title_aliases_quest_id_fkey FOREIGN KEY (quest_id) REFERENCES public.quests(id);


--
-- Name: quest_versions quest_versions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_versions
    ADD CONSTRAINT quest_versions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quest_versions quest_versions_quest_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quest_versions
    ADD CONSTRAINT quest_versions_quest_id_fkey FOREIGN KEY (quest_id) REFERENCES public.quests(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quests quests_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quests
    ADD CONSTRAINT quests_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quests_latest quests_latest_quest_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quests_latest
    ADD CONSTRAINT quests_latest_quest_id_fkey FOREIGN KEY (quest_id) REFERENCES public.quests(id) ON DELETE CASCADE;


--
-- Name: quests_latest quests_latest_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quests_latest
    ADD CONSTRAINT quests_latest_version_id_fkey FOREIGN KEY (version_id) REFERENCES public.quest_versions(id);


--
-- Name: saved_themes saved_themes_theme_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_themes
    ADD CONSTRAINT saved_themes_theme_id_fkey FOREIGN KEY (theme_id) REFERENCES public.themes(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: saved_themes saved_themes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_themes
    ADD CONSTRAINT saved_themes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: saved_videos saved_videos_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_videos
    ADD CONSTRAINT saved_videos_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: saved_videos saved_videos_video_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_videos
    ADD CONSTRAINT saved_videos_video_id_fkey FOREIGN KEY (video_id) REFERENCES public.videos(id) ON DELETE CASCADE;


--
-- Name: task_attempts task_attempts_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_attempts
    ADD CONSTRAINT task_attempts_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;


--
-- Name: task_attempts task_attempts_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_attempts
    ADD CONSTRAINT task_attempts_version_id_fkey FOREIGN KEY (version_id) REFERENCES public.task_versions(id) ON DELETE CASCADE;


--
-- Name: task_solutions task_solutions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_solutions
    ADD CONSTRAINT task_solutions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: task_solutions task_solutions_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_solutions
    ADD CONSTRAINT task_solutions_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: task_solves task_solves_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_solves
    ADD CONSTRAINT task_solves_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: task_solves task_solves_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_solves
    ADD CONSTRAINT task_solves_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: task_versions task_versions_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_versions
    ADD CONSTRAINT task_versions_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;


--
-- Name: tasks tasks_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: tasks tasks_current_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_current_version_id_fkey FOREIGN KEY (current_version_id) REFERENCES public.task_versions(id) ON DELETE SET NULL;


--
-- Name: theme_comments theme_comments_theme_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_comments
    ADD CONSTRAINT theme_comments_theme_id_fkey FOREIGN KEY (theme_id) REFERENCES public.themes(id) ON DELETE CASCADE;


--
-- Name: theme_comments theme_comments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_comments
    ADD CONSTRAINT theme_comments_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: theme_likes theme_likes_theme_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_likes
    ADD CONSTRAINT theme_likes_theme_id_fkey FOREIGN KEY (theme_id) REFERENCES public.themes(id) ON DELETE CASCADE;


--
-- Name: theme_likes theme_likes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_likes
    ADD CONSTRAINT theme_likes_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: themes themes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.themes
    ADD CONSTRAINT themes_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: themes themes_original_theme_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.themes
    ADD CONSTRAINT themes_original_theme_id_fkey FOREIGN KEY (original_theme_id) REFERENCES public.themes(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: user_interactions user_interactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_interactions
    ADD CONSTRAINT user_interactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: user_interactions user_interactions_video_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_interactions
    ADD CONSTRAINT user_interactions_video_id_fkey FOREIGN KEY (video_id) REFERENCES public.videos(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: user_streaks user_streaks_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_streaks
    ADD CONSTRAINT user_streaks_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: user_warnings user_warnings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_warnings
    ADD CONSTRAINT user_warnings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: video_reports video_reports_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_reports
    ADD CONSTRAINT video_reports_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: video_reports video_reports_video_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_reports
    ADD CONSTRAINT video_reports_video_id_fkey FOREIGN KEY (video_id) REFERENCES public.videos(id) ON DELETE CASCADE;


--
-- Name: video_tags video_tags_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_tags
    ADD CONSTRAINT video_tags_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.tags(id) ON DELETE CASCADE;


--
-- Name: video_tags video_tags_video_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_tags
    ADD CONSTRAINT video_tags_video_id_fkey FOREIGN KEY (video_id) REFERENCES public.videos(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: videos videos_author_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.videos
    ADD CONSTRAINT videos_author_id_fkey FOREIGN KEY (author_id) REFERENCES public.profiles(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: dislikes Auth insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Auth insert" ON public.dislikes FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: follows Auth insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Auth insert" ON public.follows FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = follower_id));


--
-- Name: likes Auth insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Auth insert" ON public.likes FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: messages Auth insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Auth insert" ON public.messages FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.conversation_members cm
  WHERE ((cm.profile_id = ( SELECT auth.uid() AS uid)) AND (cm.conversation_id = cm.conversation_id)))));


--
-- Name: profiles Auth insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Auth insert" ON public.profiles FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = id));


--
-- Name: saved_videos Auth insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Auth insert" ON public.saved_videos FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: video_reports Auth insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Auth insert" ON public.video_reports FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: messages Auth update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Auth update" ON public.messages FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM public.conversation_members cm
  WHERE ((cm.profile_id = ( SELECT auth.uid() AS uid)) AND (cm.conversation_id = cm.conversation_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.conversation_members cm
  WHERE ((cm.profile_id = ( SELECT auth.uid() AS uid)) AND (cm.conversation_id = cm.conversation_id)))));


--
-- Name: comments Public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public read" ON public.comments FOR SELECT USING (true);


--
-- Name: conversation_members Public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public read" ON public.conversation_members FOR SELECT USING (true);


--
-- Name: dislikes Public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public read" ON public.dislikes FOR SELECT USING (true);


--
-- Name: follows Public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public read" ON public.follows FOR SELECT USING (true);


--
-- Name: likes Public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public read" ON public.likes FOR SELECT USING (true);


--
-- Name: profiles Public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public read" ON public.profiles FOR SELECT USING (true);


--
-- Name: saved_videos Public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public read" ON public.saved_videos FOR SELECT USING (true);


--
-- Name: tags Public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public read" ON public.tags FOR SELECT USING (true);


--
-- Name: video_reports Public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public read" ON public.video_reports FOR SELECT USING (true);


--
-- Name: video_tags Public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public read" ON public.video_tags FOR SELECT USING (true);


--
-- Name: conversations Users can create conversations; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can create conversations" ON public.conversations FOR INSERT WITH CHECK ((created_by = ( SELECT auth.uid() AS uid)));


--
-- Name: dislikes admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin all" ON public.dislikes TO supabase_admin USING (true) WITH CHECK (true);


--
-- Name: follows admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin all" ON public.follows TO supabase_admin USING (true) WITH CHECK (true);


--
-- Name: likes admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin all" ON public.likes TO supabase_admin USING (true) WITH CHECK (true);


--
-- Name: profiles admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin all" ON public.profiles TO supabase_admin USING (true) WITH CHECK (true);


--
-- Name: tags admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin all" ON public.tags TO supabase_admin USING (true) WITH CHECK (true);


--
-- Name: video_tags admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin all" ON public.video_tags TO supabase_admin USING (true) WITH CHECK (true);


--
-- Name: videos admin all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin all" ON public.videos TO supabase_admin USING (true) WITH CHECK (true);


--
-- Name: quest_connections admin update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin update" ON public.quest_connections FOR UPDATE TO supabase_admin, postgres USING (true);


--
-- Name: quest_connection_versions admin update / delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin update / delete" ON public.quest_connection_versions TO supabase_admin, postgres USING (true);


--
-- Name: quest_versions admin update / delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin update / delete" ON public.quest_versions TO supabase_admin, postgres USING (true);


--
-- Name: ban_appeals admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admin_all ON public.ban_appeals TO dashboard_user, supabase_auth_admin, postgres USING (true) WITH CHECK (true);


--
-- Name: ai_bots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ai_bots ENABLE ROW LEVEL SECURITY;

--
-- Name: applied_themes all own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "all own" ON public.applied_themes USING ((user_id = ( SELECT auth.uid() AS uid))) WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: user_warnings all public; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "all public" ON public.user_warnings USING (true) WITH CHECK (true);


--
-- Name: applied_themes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.applied_themes ENABLE ROW LEVEL SECURITY;

--
-- Name: likes auth delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth delete" ON public.likes FOR DELETE USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: saved_videos auth delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth delete" ON public.saved_videos FOR DELETE USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: video_reports auth delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth delete" ON public.video_reports FOR DELETE USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: videos auth delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth delete" ON public.videos FOR DELETE USING ((( SELECT auth.uid() AS uid) = author_id));


--
-- Name: quest_connection_versions auth insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth insert" ON public.quest_connection_versions FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = created_by));


--
-- Name: quest_connections auth insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth insert" ON public.quest_connections FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = created_by));


--
-- Name: quest_versions auth insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth insert" ON public.quest_versions FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = created_by));


--
-- Name: quests auth insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth insert" ON public.quests FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = created_by));


--
-- Name: conversations auth read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth read" ON public.conversations FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.conversation_members
  WHERE ((conversation_members.conversation_id = conversations.id) AND (conversation_members.profile_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: messages auth read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth read" ON public.messages FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.conversation_members cm
  WHERE ((cm.profile_id = ( SELECT auth.uid() AS uid)) AND (cm.conversation_id = cm.conversation_id)))));


--
-- Name: conversations auth update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth update" ON public.conversations FOR UPDATE USING ((( SELECT auth.uid() AS uid) = created_by));


--
-- Name: dislikes auth update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth update" ON public.dislikes FOR UPDATE USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: follows auth update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth update" ON public.follows FOR UPDATE USING ((( SELECT auth.uid() AS uid) = follower_id));


--
-- Name: profiles auth update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "auth update" ON public.profiles FOR UPDATE USING ((( SELECT auth.uid() AS uid) = id)) WITH CHECK ((( SELECT auth.uid() AS uid) = id));


--
-- Name: ban_appeals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ban_appeals ENABLE ROW LEVEL SECURITY;

--
-- Name: banned_words; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.banned_words ENABLE ROW LEVEL SECURITY;

--
-- Name: categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;

--
-- Name: comment_likes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.comment_likes ENABLE ROW LEVEL SECURITY;

--
-- Name: comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;

--
-- Name: conversation_members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.conversation_members ENABLE ROW LEVEL SECURITY;

--
-- Name: conversations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;

--
-- Name: comments delete own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "delete own" ON public.comments FOR DELETE USING ((( SELECT auth.uid() AS uid) = author_id));


--
-- Name: saved_themes delete own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "delete own" ON public.saved_themes FOR DELETE USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: theme_comments delete own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "delete own" ON public.theme_comments FOR DELETE USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: themes delete own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "delete own" ON public.themes FOR DELETE USING ((( SELECT auth.uid() AS uid) = created_by));


--
-- Name: user_interactions delete_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY delete_own ON public.user_interactions FOR DELETE USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: dislikes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.dislikes ENABLE ROW LEVEL SECURITY;

--
-- Name: follows; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.follows ENABLE ROW LEVEL SECURITY;

--
-- Name: comment_likes insert own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "insert own" ON public.comment_likes FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: comments insert own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "insert own" ON public.comments FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = author_id));


--
-- Name: conversation_members insert own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "insert own" ON public.conversation_members FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = profile_id));


--
-- Name: quest_title_aliases insert own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "insert own" ON public.quest_title_aliases FOR INSERT WITH CHECK ((created_by = ( SELECT auth.uid() AS uid)));


--
-- Name: saved_themes insert own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "insert own" ON public.saved_themes FOR INSERT WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: themes insert own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "insert own" ON public.themes FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = created_by));


--
-- Name: videos insert own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "insert own" ON public.videos FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = author_id));


--
-- Name: ban_appeals insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY insert_own ON public.ban_appeals FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: user_interactions insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY insert_own ON public.user_interactions FOR INSERT WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: likes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.likes ENABLE ROW LEVEL SECURITY;

--
-- Name: profile_settings manage own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "manage own" ON public.profile_settings USING ((user_id = ( SELECT auth.uid() AS uid))) WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: message_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.message_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: message_versions message_versions_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY message_versions_admin_read ON public.message_versions FOR SELECT USING (public.is_current_user_admin());


--
-- Name: message_versions message_versions_service_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY message_versions_service_all ON public.message_versions USING ((auth.role() = 'service_role'::text)) WITH CHECK ((auth.role() = 'service_role'::text));


--
-- Name: messages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

--
-- Name: ban_appeals own_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY own_read ON public.ban_appeals FOR SELECT USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: task_solutions owner add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "owner add" ON public.task_solutions FOR INSERT WITH CHECK (((EXISTS ( SELECT t.created_by
   FROM public.tasks t
  WHERE ((t.id = task_solutions.task_id) AND (t.created_by = t.created_by)))) AND (created_by = ( SELECT auth.uid() AS uid))));


--
-- Name: task_solutions owner delete own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "owner delete own" ON public.task_solutions FOR DELETE USING (((EXISTS ( SELECT t.created_by
   FROM public.tasks t
  WHERE ((t.id = task_solutions.task_id) AND (t.created_by = t.created_by)))) AND (created_by = ( SELECT auth.uid() AS uid))));


--
-- Name: task_solutions owner read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "owner read" ON public.task_solutions FOR SELECT USING (((EXISTS ( SELECT t.created_by
   FROM public.tasks t
  WHERE ((t.id = task_solutions.task_id) AND (t.created_by = t.created_by)))) AND (created_by = ( SELECT auth.uid() AS uid))));


--
-- Name: task_solutions owner update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "owner update" ON public.task_solutions FOR UPDATE USING (((EXISTS ( SELECT t.created_by
   FROM public.tasks t
  WHERE ((t.id = task_solutions.task_id) AND (t.created_by = t.created_by)))) AND (created_by = ( SELECT auth.uid() AS uid)))) WITH CHECK (((EXISTS ( SELECT t.created_by
   FROM public.tasks t
  WHERE ((t.id = task_solutions.task_id) AND (t.created_by = t.created_by)))) AND (created_by = ( SELECT auth.uid() AS uid))));


--
-- Name: theme_comments post comment if theme is public or own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "post comment if theme is public or own" ON public.theme_comments FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.themes t
  WHERE ((t.id = theme_comments.theme_id) AND (t.is_public OR (( SELECT auth.uid() AS uid) = t.created_by))))));


--
-- Name: pro_users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pro_users ENABLE ROW LEVEL SECURITY;

--
-- Name: profile_levels; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profile_levels ENABLE ROW LEVEL SECURITY;

--
-- Name: profile_quest_progress; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profile_quest_progress ENABLE ROW LEVEL SECURITY;

--
-- Name: profile_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profile_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: tags public insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public insert" ON public.tags FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: video_tags public insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public insert" ON public.video_tags FOR INSERT WITH CHECK (true);


--
-- Name: ai_bots public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read" ON public.ai_bots FOR SELECT USING (true);


--
-- Name: comment_likes public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read" ON public.comment_likes FOR SELECT USING (true);


--
-- Name: pro_users public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read" ON public.pro_users FOR SELECT USING (true);


--
-- Name: quest_connection_versions public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read" ON public.quest_connection_versions FOR SELECT USING (true);


--
-- Name: quest_connections public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read" ON public.quest_connections FOR SELECT USING (true);


--
-- Name: quest_connections_latest public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read" ON public.quest_connections_latest FOR SELECT USING (true);


--
-- Name: quest_title_aliases public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read" ON public.quest_title_aliases FOR SELECT USING (true);


--
-- Name: quest_versions public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read" ON public.quest_versions FOR SELECT USING (true);


--
-- Name: quests public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read" ON public.quests FOR SELECT USING (true);


--
-- Name: quests_latest public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read" ON public.quests_latest FOR SELECT USING (true);


--
-- Name: theme_likes public read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read" ON public.theme_likes FOR SELECT USING (true);


--
-- Name: theme_comments public read if referenced theme is public; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public read if referenced theme is public" ON public.theme_comments FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.themes t
  WHERE ((t.id = theme_comments.theme_id) AND (t.is_public OR (( SELECT auth.uid() AS uid) = t.created_by))))));


--
-- Name: tags public update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "public update" ON public.tags FOR UPDATE TO authenticated USING (true) WITH CHECK (true);


--
-- Name: quest_connection_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quest_connection_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: quest_connections; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quest_connections ENABLE ROW LEVEL SECURITY;

--
-- Name: quest_connections_latest; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quest_connections_latest ENABLE ROW LEVEL SECURITY;

--
-- Name: quest_title_aliases; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quest_title_aliases ENABLE ROW LEVEL SECURITY;

--
-- Name: quest_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quest_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: quests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quests ENABLE ROW LEVEL SECURITY;

--
-- Name: quests_latest; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.quests_latest ENABLE ROW LEVEL SECURITY;

--
-- Name: videos read Public; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read Public" ON public.videos FOR SELECT USING (is_published);


--
-- Name: themes read if public or own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read if public or own" ON public.themes FOR SELECT USING ((is_public OR (( SELECT auth.uid() AS uid) = created_by)));


--
-- Name: profile_levels read own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read own" ON public.profile_levels FOR SELECT USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: saved_themes read own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read own" ON public.saved_themes FOR SELECT USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: user_interactions read own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read own" ON public.user_interactions FOR SELECT USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: user_streaks read own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read own" ON public.user_streaks FOR SELECT USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: comment_likes remove own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "remove own" ON public.comment_likes FOR DELETE USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: quest_title_aliases remove own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "remove own" ON public.quest_title_aliases FOR DELETE USING ((created_by = ( SELECT auth.uid() AS uid)));


--
-- Name: saved_themes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.saved_themes ENABLE ROW LEVEL SECURITY;

--
-- Name: saved_videos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.saved_videos ENABLE ROW LEVEL SECURITY;

--
-- Name: tags; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tags ENABLE ROW LEVEL SECURITY;

--
-- Name: task_attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.task_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: task_attempts task_attempts_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY task_attempts_insert_own ON public.task_attempts FOR INSERT TO authenticated WITH CHECK ((user_id = auth.uid()));


--
-- Name: task_attempts task_attempts_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY task_attempts_select_own ON public.task_attempts FOR SELECT TO authenticated USING ((user_id = auth.uid()));


--
-- Name: task_solutions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.task_solutions ENABLE ROW LEVEL SECURITY;

--
-- Name: task_solves; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.task_solves ENABLE ROW LEVEL SECURITY;

--
-- Name: task_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.task_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: task_versions task_versions_delete_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY task_versions_delete_policy ON public.task_versions FOR DELETE TO authenticated USING ((created_by = auth.uid()));


--
-- Name: task_versions task_versions_insert_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY task_versions_insert_policy ON public.task_versions FOR INSERT TO authenticated WITH CHECK ((created_by = auth.uid()));


--
-- Name: task_versions task_versions_select_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY task_versions_select_policy ON public.task_versions FOR SELECT TO authenticated USING (((status = 'published'::text) OR (created_by = auth.uid())));


--
-- Name: task_versions task_versions_update_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY task_versions_update_policy ON public.task_versions FOR UPDATE TO authenticated USING ((created_by = auth.uid())) WITH CHECK ((created_by = auth.uid()));


--
-- Name: tasks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;

--
-- Name: tasks tasks_delete_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tasks_delete_policy ON public.tasks FOR DELETE TO authenticated USING ((created_by = auth.uid()));


--
-- Name: tasks tasks_insert_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tasks_insert_policy ON public.tasks FOR INSERT TO authenticated WITH CHECK ((created_by = auth.uid()));


--
-- Name: tasks tasks_select_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tasks_select_policy ON public.tasks FOR SELECT TO authenticated USING (((visibility = ANY (ARRAY['public'::text, 'unlisted'::text])) OR (created_by = auth.uid())));


--
-- Name: tasks tasks_update_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tasks_update_policy ON public.tasks FOR UPDATE TO authenticated USING ((created_by = auth.uid())) WITH CHECK ((created_by = auth.uid()));


--
-- Name: theme_comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.theme_comments ENABLE ROW LEVEL SECURITY;

--
-- Name: theme_likes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.theme_likes ENABLE ROW LEVEL SECURITY;

--
-- Name: themes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.themes ENABLE ROW LEVEL SECURITY;

--
-- Name: saved_themes update own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "update own" ON public.saved_themes FOR UPDATE USING ((user_id = ( SELECT auth.uid() AS uid))) WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: theme_comments update own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "update own" ON public.theme_comments FOR UPDATE USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: themes update own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "update own" ON public.themes FOR UPDATE USING ((( SELECT auth.uid() AS uid) = created_by)) WITH CHECK ((( SELECT auth.uid() AS uid) = created_by));


--
-- Name: videos update own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "update own" ON public.videos FOR UPDATE USING ((( SELECT auth.uid() AS uid) = author_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = author_id));


--
-- Name: conversation_members update self; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "update self" ON public.conversation_members FOR UPDATE USING ((( SELECT auth.uid() AS uid) = profile_id));


--
-- Name: user_interactions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_interactions ENABLE ROW LEVEL SECURITY;

--
-- Name: user_streaks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_streaks ENABLE ROW LEVEL SECURITY;

--
-- Name: user_warnings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_warnings ENABLE ROW LEVEL SECURITY;

--
-- Name: video_reports; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.video_reports ENABLE ROW LEVEL SECURITY;

--
-- Name: video_tags; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.video_tags ENABLE ROW LEVEL SECURITY;

--
-- Name: videos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.videos ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict pYYZY8AGZPdChPLsIIMsKIbe35dYKUO7tzkZGL62RSZCMOW0jZWgku1KnDuSmc5

