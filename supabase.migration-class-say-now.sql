-- =====================================================================
-- floorum migration: say-now questions visible to the whole class
--
-- Apply once to the existing project in the Supabase SQL editor, after
-- supabase.migration-anonymous-understanding.sql. Idempotent. Adds two
-- read-only functions; no table, column or row changes.
-- supabase.new.sql already includes them for a fresh project.
-- =====================================================================

-- Say-now questions (visibility = 'now') for everyone in the class, with
-- the same anonymous handling as the table functions: an anonymous asker
-- comes back as 'Anonymous' with a NULL student_id to everyone except the
-- asker (p_viewer), and so do the asker's own follow-ups. Questions the
-- faculty set aside ('avoided') are not shown to the class.
-- Follow-ups and +1s are the existing replies and reactions rows.

create or replace function public.class_now_feed(p_class_id uuid, p_viewer uuid default null)
returns table (
  id uuid, class_id uuid, student_id uuid, table_id uuid, topic_id uuid,
  anchor_id uuid, text text, visibility text, status text,
  created_at timestamptz, student_name text, anonymous boolean
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
         t.anonymous
  from public.thoughts t
  left join public.students s on s.id = t.student_id
  where t.class_id = p_class_id
    and t.visibility = 'now'
    and t.status <> 'avoided'
  order by t.created_at desc
$$;

create or replace function public.class_now_replies(p_class_id uuid, p_viewer uuid default null)
returns table (
  id uuid, thought_id uuid, student_id uuid, text text,
  created_at timestamptz, student_name text
)
language sql
stable
security invoker
set search_path = public
as $$
  select r.id, r.thought_id,
         case when t.anonymous and r.student_id = t.student_id
                   and r.student_id is distinct from p_viewer
              then null else r.student_id end,
         r.text, r.created_at,
         case when t.anonymous and r.student_id = t.student_id
              then 'Anonymous' else coalesce(s.name, 'Someone') end
  from public.replies r
  join public.thoughts t on t.id = r.thought_id
  left join public.students s on s.id = r.student_id
  where t.class_id = p_class_id
    and t.visibility = 'now'
    and t.status <> 'avoided'
  order by r.created_at asc
$$;

grant execute on function public.class_now_feed(uuid, uuid)    to anon, authenticated;
grant execute on function public.class_now_replies(uuid, uuid) to anon, authenticated;

-- PostgREST caches function signatures; make it pick up the new ones now.
notify pgrst, 'reload schema';
