-- =====================================================================
-- SayIt — complete schema for the current Supabase project
--   https://isxaiijfcyrwelcngnec.supabase.co
--
-- This is the full, authoritative schema the prototype runs on: 11 tables,
-- indexes, RLS policies, grants, 2 RPCs and the Realtime publication.
-- It is what was applied to the project above, and it is idempotent, so it
-- doubles as the recreate-from-scratch script.
--
-- supabase.sql (the older file) describes the original 5-table project and
-- is kept only for history. This file supersedes it.
--
-- Requires Postgres 13+ for gen_random_uuid(), which every Supabase
-- project satisfies. If it is somehow missing:
--   create extension if not exists pgcrypto with schema extensions;
-- =====================================================================

-- ------------------------------------------------- 1. tables

-- One row per class session. `code` is what goes on the board, `teacher_key`
-- is a random key kept on the teacher's device, `current_topic_id` is the
-- topic showing as "ON NOW".
create table if not exists public.classes (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  teacher_key      text not null,
  name             text not null,
  status           text not null default 'idle',   -- idle | live | ended
  current_topic_id uuid,                            -- FK added below
  created_at       timestamptz not null default now()
);

-- The physical tables in the room. Four are created with every class;
-- students may name their own when they join.
-- Trailing underscore because "table" is reserved, and the frontend calls
-- from("tables_") — the name is fixed.
create table if not exists public.tables_ (
  id       uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  name     text not null
);

-- One row per person per class-join. No account, no password: a display
-- name and which table they are sitting at.
create table if not exists public.students (
  id        uuid primary key default gen_random_uuid(),
  class_id  uuid not null references public.classes(id) on delete cascade,
  name      text not null,
  table_id  uuid          references public.tables_(id) on delete set null,
  joined_at timestamptz not null default now()
);

-- The running order. `subtopics` is a plain text[] of labels; `ord` is the
-- sequence. Replaced wholesale whenever the teacher applies a new outline.
create table if not exists public.topics (
  id        uuid primary key default gen_random_uuid(),
  class_id  uuid not null references public.classes(id) on delete cascade,
  title     text not null,
  subtopics text[] not null default '{}',
  ord       integer not null default 0
);

-- The deck a running order came from. One row per class with source='deck',
-- used as the parent for anchors and as the label on anchor suggestions.
create table if not exists public.materials (
  id       uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  topic_id uuid          references public.topics(id)  on delete set null,
  title    text not null,
  type     text,
  source   text
);

-- Points in the material ("Slide 11 — the action line") that a question can
-- be pinned to. The student composer word-matches against these.
create table if not exists public.anchors (
  id          uuid primary key default gen_random_uuid(),
  class_id    uuid not null references public.classes(id)   on delete cascade,
  material_id uuid          references public.materials(id) on delete cascade,
  topic_id    uuid          references public.topics(id)    on delete cascade,
  label       text not null,
  body        text,
  ord         integer not null default 0
);

-- The questions. `visibility` is where it goes, `status` is how far it got.
-- topic_id and anchor_id are SET NULL rather than CASCADE on purpose: a
-- question must survive the teacher replacing the running order.
create table if not exists public.thoughts (
  id         uuid primary key default gen_random_uuid(),
  class_id   uuid not null references public.classes(id)  on delete cascade,
  student_id uuid          references public.students(id) on delete set null,
  table_id   uuid          references public.tables_(id)  on delete set null,
  topic_id   uuid          references public.topics(id)   on delete set null,
  anchor_id  uuid          references public.anchors(id)  on delete set null,
  text       text not null,
  visibility text not null check (visibility in ('now','later','table','private')),
  status     text not null default 'captured',
             -- captured | ready | taking | spoken | addressed | avoided
             -- Deliberately unconstrained: the frontend has already added one
             -- value ('avoided') since launch and a CHECK would have blocked it.
             -- Also used: resolved (asker no longer needs it), seen / marked
             -- (faculty read / flagged to come back to).
  anonymous  boolean not null default false,
             -- per question: hide the asker's name from faculty and the table.
             -- student_id stays set so the asker keeps control of it.
  created_at timestamptz not null default now()
);
-- For projects created before the column existed.
alter table public.thoughts add column if not exists anonymous boolean not null default false;

-- The after-class list, one row per 'later' thought. Keyed on thought_id so
-- the frontend's upsert is idempotent.
create table if not exists public.queue (
  thought_id    uuid primary key references public.thoughts(id) on delete cascade,
  class_id      uuid not null    references public.classes(id)  on delete cascade,
  status        text not null default 'pending',  -- pending | scheduled | answered
  scheduled_for text,
  response      text
);

-- Follow-ups on a table-shared question.
create table if not exists public.replies (
  id         uuid primary key default gen_random_uuid(),
  thought_id uuid not null references public.thoughts(id) on delete cascade,
  student_id uuid          references public.students(id) on delete set null,
  text       text not null,
  created_at timestamptz not null default now()
);

-- "Same question" at a table. The composite primary key gives one per
-- student and makes a double-tap harmless.
create table if not exists public.reactions (
  thought_id uuid not null references public.thoughts(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (thought_id, student_id)
);

-- Per-student, per-subtopic understanding: Well = 1, Somewhat = 0, Not well = -1.
-- subtopic_idx is the position in topics.subtopics; -1 means the topic as a
-- whole, which is what a topic with no subtopics votes on.
-- The primary key gives one current vote per student per subtopic, so an
-- opposite vote replaces rather than accumulates.
-- Cascading from topics means replacing the running order clears stale
-- feedback by itself: a new outline is a new set of subtopics.
create table if not exists public.topic_pulse (
  class_id     uuid        not null references public.classes(id)  on delete cascade,
  topic_id     uuid        not null references public.topics(id)   on delete cascade,
  subtopic_idx smallint    not null,
  student_id   uuid        not null references public.students(id) on delete cascade,
  value        smallint    not null,
  updated_at   timestamptz not null default now(),
  primary key (topic_id, subtopic_idx, student_id)
);
alter table public.topic_pulse drop constraint if exists topic_pulse_value_check;
alter table public.topic_pulse add constraint topic_pulse_value_check check (value in (1, 0, -1));

-- classes.current_topic_id, added once topics exists.
-- SET NULL is load-bearing: applying a new running order deletes every topic
-- for the class before inserting the replacements.
do $$
begin
  alter table public.classes
    add constraint classes_current_topic_id_fkey
    foreign key (current_topic_id) references public.topics(id) on delete set null;
exception
  when duplicate_object then null;
end
$$;

-- ------------------------------------------------- 2. indexes
-- Postgres does not index foreign keys automatically. These cover the
-- frontend's filters and the cascade deletes.

create index if not exists tables__class_idx        on public.tables_    (class_id);
create index if not exists students_class_idx       on public.students   (class_id);
create index if not exists students_table_idx       on public.students   (table_id);
create index if not exists topics_class_ord_idx     on public.topics     (class_id, ord);
create index if not exists materials_class_src_idx  on public.materials  (class_id, source);
create index if not exists materials_topic_idx      on public.materials  (topic_id);
create index if not exists anchors_class_ord_idx    on public.anchors    (class_id, ord);
create index if not exists anchors_material_idx     on public.anchors    (material_id);
create index if not exists anchors_topic_idx        on public.anchors    (topic_id);
create index if not exists thoughts_class_time_idx  on public.thoughts   (class_id, created_at desc);
create index if not exists thoughts_table_vis_idx   on public.thoughts   (table_id, visibility);
create index if not exists thoughts_student_idx     on public.thoughts   (student_id);
create index if not exists thoughts_topic_idx       on public.thoughts   (topic_id);
create index if not exists thoughts_anchor_idx      on public.thoughts   (anchor_id);
create index if not exists queue_class_idx          on public.queue      (class_id);
create index if not exists replies_thought_idx      on public.replies    (thought_id);
create index if not exists replies_student_idx      on public.replies    (student_id);
create index if not exists reactions_student_idx    on public.reactions  (student_id);
create index if not exists topic_pulse_class_idx    on public.topic_pulse(class_id);
create index if not exists topic_pulse_student_idx  on public.topic_pulse(student_id);

-- ------------------------------------------------- 3. RLS
-- The prototype has no accounts: every device carries the same publishable
-- key and identifies itself only by a class code. These policies match that.
-- Anyone holding the key can read and write every row in every class, and
-- table-private thoughts are hidden by the UI rather than by the database.
-- Tightening this needs frontend changes in lockstep.

alter table public.classes     enable row level security;
alter table public.tables_     enable row level security;
alter table public.students    enable row level security;
alter table public.topics      enable row level security;
alter table public.materials   enable row level security;
alter table public.anchors     enable row level security;
alter table public.thoughts    enable row level security;
alter table public.queue       enable row level security;
alter table public.replies     enable row level security;
alter table public.reactions   enable row level security;
alter table public.topic_pulse enable row level security;

do $$
declare t text;
begin
  foreach t in array array[
    'classes','tables_','students','topics','materials','anchors',
    'thoughts','queue','replies','reactions','topic_pulse'
  ] loop
    execute format('drop policy if exists %I on public.%I', t || '_read',  t);
    execute format('drop policy if exists %I on public.%I', t || '_write', t);
    execute format('create policy %I on public.%I for select using (true)', t || '_read', t);
    execute format('create policy %I on public.%I for all using (true) with check (true)', t || '_write', t);
  end loop;
end
$$;

-- ------------------------------------------------- 4. grants

grant usage on schema public to anon, authenticated;

grant select, insert, update, delete on
  public.classes, public.tables_, public.students, public.topics,
  public.materials, public.anchors, public.thoughts, public.queue,
  public.replies, public.reactions, public.topic_pulse
to anon, authenticated;

-- ------------------------------------------------- 5. functions
-- The two RPCs the student's table view calls. Column lists match exactly
-- what the frontend reads. STABLE, so they are read-only.

-- p_viewer: the student asking. An anonymous question (and its asker's own
-- follow-ups) comes back as 'Anonymous' with a NULL student_id to everyone else.
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

-- ------------------------------------------------- 6. realtime
-- The eight tables the frontend subscribes to. REPLICA IDENTITY FULL is
-- required so DELETE events still carry class_id and therefore still match
-- the channel's class_id filter.
--
-- tables_, materials and anchors are deliberately not published: nothing
-- subscribes to them, and a new students row already triggers the reload
-- that re-reads them.
--
-- replies and reactions are subscribed without a filter because neither
-- table has a class_id to filter on.

alter table public.thoughts    replica identity full;
alter table public.queue       replica identity full;
alter table public.classes     replica identity full;
alter table public.topics      replica identity full;
alter table public.students    replica identity full;
alter table public.replies     replica identity full;
alter table public.reactions   replica identity full;
alter table public.topic_pulse replica identity full;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'thoughts','queue','classes','topics','students',
    'replies','reactions','topic_pulse'
  ] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception
      when duplicate_object then null;
    end;
  end loop;
end
$$;
