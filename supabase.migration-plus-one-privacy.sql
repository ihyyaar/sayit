-- =====================================================================
-- floorum migration: the +1 count is the asker's to see
--
-- Apply once in the Supabase SQL editor, after
-- supabase.migration-class-say-now.sql. Idempotent. Replaces two read-only
-- functions; no table, column or row changes.
-- supabase.new.sql already includes this for a fresh project.
--
-- Why: students used to read the reactions rows themselves and count them
-- in the browser, so every tablemate could see how many +1s a question had.
-- Now the feeds return:
--   reaction_count  the number of +1s, but only to the student who asked
--                   (NULL for everyone else, so the number never leaves
--                   the database)
--   reacted_by_me   whether the viewer has +1'd it, which is all anyone
--                   else needs to press or unpress +1
-- Faculty still count the reactions rows directly, as they always have.
-- =====================================================================

drop function if exists public.table_feed(uuid, uuid);
drop function if exists public.class_now_feed(uuid, uuid);

create or replace function public.table_feed(p_table_id uuid, p_viewer uuid default null)
returns table (
  id uuid, class_id uuid, student_id uuid, table_id uuid, topic_id uuid,
  anchor_id uuid, text text, visibility text, status text,
  created_at timestamptz, student_name text, anonymous boolean,
  reaction_count integer, reacted_by_me boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  select t.id, t.class_id,
         case when t.anonymous and t.student_id is distinct from p_viewer
              then null else t.student_id end,
         t.table_id, t.topic_id, t.anchor_id, t.text, t.visibility, t.status,
         t.created_at,
         case when t.anonymous then 'Anonymous' else coalesce(s.name, 'Someone') end,
         t.anonymous,
         case when t.student_id is not distinct from p_viewer
              then (select count(*) from public.reactions x where x.thought_id = t.id)::int
              else null end,
         exists (select 1 from public.reactions x
                 where x.thought_id = t.id and x.student_id = p_viewer)
  from public.thoughts t
  left join public.students s on s.id = t.student_id
  where t.table_id = p_table_id
    and t.visibility = 'table'
  order by t.created_at desc
$$;

create or replace function public.class_now_feed(p_class_id uuid, p_viewer uuid default null)
returns table (
  id uuid, class_id uuid, student_id uuid, table_id uuid, topic_id uuid,
  anchor_id uuid, text text, visibility text, status text,
  created_at timestamptz, student_name text, anonymous boolean,
  reaction_count integer, reacted_by_me boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  select t.id, t.class_id,
         case when t.anonymous and t.student_id is distinct from p_viewer
              then null else t.student_id end,
         t.table_id, t.topic_id, t.anchor_id, t.text, t.visibility, t.status,
         t.created_at,
         case when t.anonymous then 'Anonymous' else coalesce(s.name, 'Someone') end,
         t.anonymous,
         case when t.student_id is not distinct from p_viewer
              then (select count(*) from public.reactions x where x.thought_id = t.id)::int
              else null end,
         exists (select 1 from public.reactions x
                 where x.thought_id = t.id and x.student_id = p_viewer)
  from public.thoughts t
  left join public.students s on s.id = t.student_id
  where t.class_id = p_class_id
    and t.visibility = 'now'
    and t.status <> 'avoided'
  order by t.created_at desc
$$;

grant execute on function public.table_feed(uuid, uuid)     to anon, authenticated;
grant execute on function public.class_now_feed(uuid, uuid) to anon, authenticated;

-- PostgREST caches function signatures; make it pick up the new ones now.
notify pgrst, 'reload schema';
