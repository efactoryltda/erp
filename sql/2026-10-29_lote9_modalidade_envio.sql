-- ============================================================
-- ERP E-Factory — LOTE 9 (banco)
-- Modalidade de envio de cada pedido (Full, Flex, Coleta, Agência,
-- Envio próprio, Balcão) para a tag de canal/envio na tela.
--
-- Só ADICIONA: uma coluna, um gatilho que preenche o padrão e
-- funções de filtro novas (_v3). Não altera valores, estoque,
-- faturamento nem as funções que a tela usa hoje.
--
-- Histórico: NÃO consulta o Mercado Livre (decisão de 29/10/2026).
--   pedido ML com baixa no Full  -> 'full'
--   pedido ML com baixa no físico -> 'envio_proprio'
--   loja física                   -> 'balcao'
-- Pedidos novos do ML recebem a modalidade real pelo webhook.
-- ============================================================
begin;

alter table pedidos_venda
  add column if not exists modalidade_envio text;

alter table pedidos_venda drop constraint if exists pedidos_venda_modalidade_envio_check;
alter table pedidos_venda add constraint pedidos_venda_modalidade_envio_check
  check (modalidade_envio is null or modalidade_envio in
         ('full', 'flex', 'coleta', 'agencia', 'envio_proprio', 'balcao'));

comment on column pedidos_venda.modalidade_envio is
  'Como o pedido sai: full, flex, coleta, agencia, envio_proprio ou balcao. ML novo: vem do logistic_type do envio.';

-- Padrão quando quem cria o pedido não informa (PDV manual, loja online)
create or replace function preencher_modalidade_envio()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.modalidade_envio is null then
    new.modalidade_envio := case
      when new.local_baixa_estoque::text like 'full%' then 'full'
      when new.canal = 'loja_fisica' then 'balcao'
      else 'envio_proprio'
    end;
  end if;
  return new;
end $$;

drop trigger if exists trg_preencher_modalidade_envio on pedidos_venda;
create trigger trg_preencher_modalidade_envio
  before insert on pedidos_venda
  for each row execute function preencher_modalidade_envio();

-- Histórico (só a coluna nova; o gatilho de contas a receber não olha esta coluna)
update pedidos_venda set modalidade_envio = case
    when local_baixa_estoque::text like 'full%' then 'full'
    when canal = 'loja_fisica' then 'balcao'
    else 'envio_proprio'
  end
where modalidade_envio is null;

create index if not exists idx_pedidos_venda_modalidade on pedidos_venda(modalidade_envio);

-- ------------------------------------------------------------
-- Filtros com modalidade (versão 3). Mesmas regras da v2 + p_modalidade.
-- ------------------------------------------------------------
create or replace function filtrar_pedidos_venda_v3(
  p_inicio timestamptz, p_fim timestamptz, p_canal text,
  p_produto uuid, p_texto text, p_modalidade text
)
returns setof pedidos_venda
language sql stable security invoker set search_path = public
as $$
  select * from filtrar_pedidos_venda(p_inicio, p_fim, p_canal, p_produto, p_texto)
  where p_modalidade is null or modalidade_envio = p_modalidade
$$;

create or replace function listar_pedidos_filtro_ids_v3(
  p_inicio timestamptz, p_fim timestamptz, p_canal text,
  p_produto uuid, p_texto text, p_modalidade text, p_limite int, p_offset int
)
returns setof uuid
language sql stable security invoker set search_path = public
as $$
  select id from filtrar_pedidos_venda_v3(p_inicio, p_fim, p_canal, p_produto, p_texto, p_modalidade)
  order by data_pedido desc, id desc
  limit greatest(p_limite, 0) offset greatest(p_offset, 0)
$$;

create or replace function resumo_vendas_filtro_v3(
  p_inicio timestamptz, p_fim timestamptz, p_canal text,
  p_produto uuid, p_texto text, p_modalidade text
)
returns table (total_pedidos bigint, pedidos_confirmados bigint, faturamento numeric)
language sql stable security invoker set search_path = public
as $$
  select count(*)::bigint,
         count(*) filter (where status = 'confirmado')::bigint,
         coalesce(sum(valor_total) filter (where status = 'confirmado'), 0)::numeric
  from filtrar_pedidos_venda_v3(p_inicio, p_fim, p_canal, p_produto, p_texto, p_modalidade)
$$;

grant execute on function filtrar_pedidos_venda_v3(timestamptz, timestamptz, text, uuid, text, text) to authenticated;
grant execute on function listar_pedidos_filtro_ids_v3(timestamptz, timestamptz, text, uuid, text, text, int, int) to authenticated;
grant execute on function resumo_vendas_filtro_v3(timestamptz, timestamptz, text, uuid, text, text) to authenticated;

-- ------------------------------------------------------------
-- CONFERÊNCIA: sem modalidade, a v3 tem que bater 100% com a v2;
-- e nenhum pedido pode ficar sem modalidade.
-- ------------------------------------------------------------
do $$
declare
  canais text[] := array[null, 'ml_conta1', 'ml_conta2', 'ml_conta3', 'loja_fisica'];
  c text; v2 record; v3 record; soma numeric; total numeric; sem int;
begin
  foreach c in array canais loop
    select * into v2 from resumo_vendas_filtro_v2(null, null, c, null, null);
    select * into v3 from resumo_vendas_filtro_v3(null, null, c, null, null, null);
    if v2 is distinct from v3 then
      raise exception 'PARADO: v3 difere da v2 no canal % (% x %)', c, v2, v3;
    end if;
  end loop;
  select count(*) into sem from pedidos_venda where modalidade_envio is null;
  if sem > 0 then raise exception 'PARADO: % pedido(s) sem modalidade', sem; end if;
  select sum(t.total_pedidos) into soma from unnest(array['full','flex','coleta','agencia','envio_proprio','balcao']) m,
    lateral resumo_vendas_filtro_v3(null, null, null, null, null, m) t;
  select count(*) into total from pedidos_venda;
  if soma <> total then raise exception 'PARADO: soma por modalidade (%) <> total (%)', soma, total; end if;
end $$;

commit;

select modalidade_envio, count(*) from pedidos_venda group by 1 order by 1;

-- ============================================================
-- LOTE 9b — varredura de pedidos do ML a cada 15 min (já aplicado em 29/10/2026)
-- Edge Function: supabase/functions/ml-sync-pedidos.ts
-- Minutos 7/22/37/52 pra não coincidir com o sync-receber (0/15/30/45).
-- ============================================================
-- select cron.schedule('sync-pedidos-ml', '7,22,37,52 * * * *', $$
--   select net.http_post(
--     url     := 'https://jrkuzyhobgzhjjyblmed.supabase.co/functions/v1/ml-sync-pedidos?horas=3',
--     headers := '{"Content-Type": "application/json"}'::jsonb,
--     body    := '{}'::jsonb,
--     timeout_milliseconds := 60000
--   ) as request_id;
-- $$);

-- Lote 9c — líquido do filtro com modalidade (aplicado em 29/10/2026; sem filtro, igual à resumo_liquido_filtro)
create or replace function resumo_liquido_filtro_v3(
  p_inicio timestamptz, p_fim timestamptz, p_canal text,
  p_produto uuid, p_texto text, p_modalidade text
)
returns table (liquido numeric, pedidos_com_liquido bigint, pedidos_ml_sem_liquido bigint, bruto_dos_com_liquido numeric)
language sql stable set search_path = public
as $$
  select
    coalesce(sum(valor_liquido) filter (where status = 'confirmado' and valor_liquido is not null), 0)::numeric,
    count(*) filter (where status = 'confirmado' and valor_liquido is not null)::bigint,
    count(*) filter (where status = 'confirmado' and ml_order_id is not null and valor_liquido is null)::bigint,
    coalesce(sum(valor_total) filter (where status = 'confirmado' and valor_liquido is not null), 0)::numeric
  from filtrar_pedidos_venda_v3(p_inicio, p_fim, p_canal, p_produto, p_texto, p_modalidade)
$$;
grant execute on function resumo_liquido_filtro_v3(timestamptz, timestamptz, text, uuid, text, text) to authenticated;
