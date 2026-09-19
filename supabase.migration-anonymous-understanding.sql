-- =====================================================================
-- floorum migration: anonymous questions + three-state understanding
--
-- Apply once to the existing project in the Supabase SQL editor
-- (https://isxaiijfcyrwelcngnec.supabase.co). Idempotent, and it keeps every
-- existing row: no question, reply or rating is deleted or rewritten.
-- supabase.new.sql already includes these changes for a fresh project.
-- =====================================================================

-- ------------------------------------------------- 1. anonymous questions
-- A per-question display setting chosen in the composer ("Show my name").
-- student_id stays set, so the asker can still edit, delete, take back, reply
-- and be queued; only the name shown to others changes. Default false: every
-- existing question stays named.
alter table public.thoughts
  add column if not exists anonymous boolean not null default false;

-- ------------------------------------------------- 2. three-state understanding
-- Well = 1, Somewhat = 0, Not well = -1. Existing 1 / -1 ratings keep their
-- meaning; only the allowed set widens.
alter table public.topic_pulse drop constraint if exists topic_pulse_value_check;
alter table public.topic_pulse
  add constraint topic_pulse_value_check check (value in (1, 0, -1));

-- ------------------------------------------------- 3. table RPCs
-- The table view reads questions and follow-ups through these two functions.
-- They now take the viewing student (p_viewer) and, for an anonymous
-- question, return 'Anonymous' and a NULL student_id to everyone else, for
-- the question and for the asker's own follow-ups on it. The asker still
-- gets their own id back, so their controls keep working.
--
-- Postgres can't change a function's arguments or result columns in place,
-- so the one-argument versions are dropped first (a second overload would
-- also make PostgREST's choice ambiguous).
drop function if exists public.table_feed(uuid);
drop function if exists public.table_replies(uuid);

create or replace function public.table_feed(p_table_id uuid, p_viewer uuid default null)
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
  where t.table_id = p_table_id
    and t.visibility = 'table'
  order by t.created_at desc
$$;

create or replace function public.table_replies(p_table_id uuid, p_viewer uuid default null)
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
  where t.table_id = p_table_id
    and t.visibility = 'table'
  order by r.created_at asc
$$;

grant execute on function public.table_feed(uuid, uuid)    to anon, authenticated;
grant execute on function public.table_replies(uuid, uuid) to anon, authenticated;

-- PostgREST caches function signatures; make it pick up the new ones now.
notify pgrst, 'reload schema';

-- ------------------------------------------------- note on the limits
-- The prototype has no accounts and its RLS lets anyone holding the
-- publishable key read every table (see supabase.new.sql, section 3). The
-- apps never show an anonymous asker's name, and the table RPCs above never
-- return it, but a hand-written query against public.thoughts still could.
-- Closing that needs real authentication and per-role policies.
