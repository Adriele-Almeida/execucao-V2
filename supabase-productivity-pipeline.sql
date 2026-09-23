-- Esteira de Produtividade — aplicada em 2026-09-14
-- Mantém GitHub e Supabase sincronizados para esta funcionalidade.

begin;

alter table public.posts drop constraint if exists posts_status_check;
alter table public.posts add constraint posts_status_check
check (status is null or status = any (array['Criar','Conferir','Refinar','Pronto','Programar','Programado','Publicado','Concluído']));

alter table public.custom_cards drop constraint if exists custom_cards_stage_check;
alter table public.custom_cards add constraint custom_cards_stage_check
check (stage is null or stage = any (array['criar','conferir','refinar','pronto','programar','programado','publicado','concluido']));

alter table public.card_updates drop constraint if exists card_updates_stage_values_check;
alter table public.card_updates add constraint card_updates_stage_values_check
check (
  (from_stage is null or from_stage = any (array['criar','conferir','refinar','pronto','programar','programado','publicado','concluido']))
  and
  (to_stage is null or to_stage = any (array['criar','conferir','refinar','pronto','programar','programado','publicado','concluido']))
);

create index if not exists posts_productivity_lookup_idx on public.posts (client_id,status,post_date);
create index if not exists custom_cards_productivity_lookup_idx on public.custom_cards (client_id,stage,created_at desc);

do $$ begin
  alter publication supabase_realtime add table public.card_updates;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.card_notifications;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.client_cards;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.profiles;
exception when duplicate_object then null;
end $$;

commit;
