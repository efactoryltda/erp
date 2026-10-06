-- ============================================================
-- ERP E-Factory — LOTE 4 (banco) — CONTAS A RECEBER
--   • Cria a tabela lancamentos_financeiros (base de contas a receber,
--     preparada pra contas a pagar / DRE no futuro: natureza, categoria,
--     bruto, tarifa, frete, taxas, ajustes, líquido, imposto, custo).
--   • Vendas do PDV / loja (sem pedido ML) entram sozinhas via trigger.
--   • Vendas do ML entram pela Edge Function ml-sync-receber.
--   • Custo: ficha técnica (kit = soma dos componentes) ou custo do cadastro.
--     Produto sem custo => NÃO entra no lucro (aviso na tela).
--   • Função de cancelamento de pedido ML (usada pelas Edge Functions)
--     pra tirar do faturamento venda que o ML cancelou.
--   • Este script NÃO cancela nada e NÃO mexe no faturamento nem no
--     estoque — confere isso sozinho no fim (foto antes/depois).
--
-- Cole TUDO no Supabase → SQL Editor → RUN ("Run without RLS" se avisar).
-- ============================================================
begin;

-- ---------- pré-requisitos ----------
do $$
begin
  if to_regclass('public.vw_custo_ficha') is null then
    raise exception 'PARADO: a view vw_custo_ficha não existe. Nada foi aplicado.';
  end if;
  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'vw_custo_ficha'
        and column_name in ('produto_id', 'custo_ficha', 'componentes_sem_custo')) <> 3 then
    raise exception 'PARADO: a vw_custo_ficha mudou de formato. Nada foi aplicado.';
  end if;
  if to_regproc('public.cancelar_pedido_venda') is null then
    raise exception 'PARADO: cancelar_pedido_venda não existe. Nada foi aplicado.';
  end if;
end $$;

-- Foto ANTES (faturamento + estoque) pra provar no fim que nada mudou
create temp table _antes on commit drop as
  select (select count(*) from pedidos_venda) as n,
         (select count(*) filter (where status = 'confirmado') from pedidos_venda) as n_conf,
         (select coalesce(sum(valor_total) filter (where status = 'confirmado'), 0) from pedidos_venda) as fat,
         (select coalesce(sum(valor_liquido), 0) from pedidos_venda) as liq,
         (select coalesce(sum(quantidade), 0) from estoque_saldos) as estoque;

-- ---------- colunas novas em pedidos_venda (só acréscimo) ----------
alter table pedidos_venda
  add column if not exists cancelado_ml_em          timestamptz,  -- quando o ERP registrou o cancelamento vindo do ML
  add column if not exists cancelamento_estoque     text,         -- devolvido | nao_devolvido
  add column if not exists receber_sincronizado_em  timestamptz;  -- última leitura dos pagamentos (contas a receber)

-- ---------- tabela principal ----------
create table if not exists lancamentos_financeiros (
  id                 uuid primary key default gen_random_uuid(),
  natureza           text not null default 'receber' check (natureza in ('receber', 'pagar')),
  origem             text not null check (origem in ('ml', 'pedido', 'manual')),
  canal              text not null check (canal in ('ml_conta1', 'ml_conta2', 'ml_conta3', 'loja_fisica', 'loja_online', 'outros')),
  categoria          text not null default 'venda' check (categoria in ('venda', 'aporte', 'outros')),
  descricao          text,
  pedido_id          uuid references pedidos_venda(id) on delete cascade,
  ml_order_id        text,
  ml_payment_id      text,
  data_competencia   timestamptz not null,             -- data da venda / do lançamento
  data_liberacao     timestamptz,                      -- data informada pelo ML (ou digitada)
  liberacao_editada  boolean not null default false,   -- true = alguém mudou a data na mão (pedido PDV)
  status             text not null check (status in ('aguardando', 'a_receber', 'recebido', 'estornado')),
  ml_payment_status  text,                             -- status cru do Mercado Pago (approved, refunded…)
  ml_release_status  text,                             -- money_release_status cru (pending, released…)
  parcelas           integer,
  valor_bruto        numeric(14,2) not null default 0,
  tarifa             numeric(14,2) not null default 0, -- tarifa de venda do ML
  frete              numeric(14,2) not null default 0, -- frete pago pelo vendedor (já descontado o que o comprador pagou)
  taxas              numeric(14,2) not null default 0, -- taxas Mercado Pago / taxas do canal
  outros_ajustes     numeric(14,2) not null default 0, -- diferença pra fechar bruto − descontos = líquido
  valor_reembolsado  numeric(14,2) not null default 0,
  valor_liquido      numeric(14,2) not null default 0, -- o que entra de fato
  imposto            numeric(14,2),                    -- futuro (DRE) — vazio por enquanto
  custo_manual       numeric(14,2),                    -- só lançamento manual (opcional)
  observacao         text,
  dados_ml           jsonb,                            -- resumo cru do pagamento (auditoria)
  sincronizado_em    timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint chk_lanc_ml      check (origem <> 'ml' or (ml_payment_id is not null and pedido_id is not null)),
  constraint chk_lanc_pedido  check (origem <> 'pedido' or pedido_id is not null),
  constraint chk_lanc_data    check (data_liberacao is not null or status in ('aguardando', 'estornado')),
  constraint chk_lanc_custo   check (custo_manual is null or custo_manual >= 0)
);

-- índice único "cheio" (sem WHERE) pra Edge Function poder fazer upsert por ml_payment_id;
-- vários NULL continuam permitidos (lançamentos que não são do ML)
create unique index if not exists uq_lanc_ml_payment on lancamentos_financeiros(ml_payment_id);
create unique index if not exists uq_lanc_pedido      on lancamentos_financeiros(pedido_id) where origem = 'pedido';
create index if not exists idx_lanc_liberacao on lancamentos_financeiros(natureza, data_liberacao);
create index if not exists idx_lanc_competencia on lancamentos_financeiros(natureza, data_competencia);
create index if not exists idx_lanc_pedido on lancamentos_financeiros(pedido_id);
create index if not exists idx_lanc_status on lancamentos_financeiros(status);
create index if not exists idx_pedidos_ml_receber_sync on pedidos_venda(receber_sincronizado_em) where ml_order_id is not null;

alter table lancamentos_financeiros enable row level security;
drop policy if exists lanc_select on lancamentos_financeiros;
drop policy if exists lanc_insert on lancamentos_financeiros;
drop policy if exists lanc_update on lancamentos_financeiros;
drop policy if exists lanc_delete on lancamentos_financeiros;
-- leitura pra quem está logado; pelo site só dá pra criar/apagar lançamento MANUAL
-- e editar manual ou a data de liberação de pedido do PDV. Lançamento do ML só
-- a Edge Function (service_role) grava.
create policy lanc_select on lancamentos_financeiros for select to authenticated using (true);
create policy lanc_insert on lancamentos_financeiros for insert to authenticated with check (origem = 'manual');
create policy lanc_update on lancamentos_financeiros for update to authenticated
  using (origem in ('manual', 'pedido')) with check (origem in ('manual', 'pedido'));
create policy lanc_delete on lancamentos_financeiros for delete to authenticated using (origem = 'manual');
revoke all on lancamentos_financeiros from anon;
grant select, insert, update, delete on lancamentos_financeiros to authenticated;

-- ---------- custo unitário de cada produto ----------
-- ficha técnica completa → custo da ficha (kit = soma dos componentes, todos os níveis)
-- ficha com componente sem custo → SEM CUSTO (não chuta)
-- sem ficha → custo do cadastro (custo_atual) se > 0, senão SEM CUSTO
create or replace view vw_custo_unitario with (security_invoker = true) as
  select p.id as produto_id,
         case
           when f.produto_id is not null then
             case when coalesce(f.componentes_sem_custo, 0) > 0 or coalesce(f.custo_ficha, 0) <= 0 then null
                  else f.custo_ficha end
           when coalesce(p.custo_atual, 0) > 0 then p.custo_atual
           else null
         end as custo_unitario,
         case
           when f.produto_id is not null then
             case when coalesce(f.componentes_sem_custo, 0) > 0 or coalesce(f.custo_ficha, 0) <= 0 then 'ficha_incompleta' else 'ficha' end
           when coalesce(p.custo_atual, 0) > 0 then 'cadastro'
           else 'sem_custo'
         end as fonte_custo
  from produtos p
  left join vw_custo_ficha f on f.produto_id = p.id;

grant select on vw_custo_unitario to authenticated;

-- ---------- PDV / loja: pedido sem ML vira lançamento sozinho ----------
create or replace function sync_lancamento_pedido()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.ml_order_id is not null then
    return new;                      -- venda do ML: quem cuida é a Edge Function
  end if;

  insert into lancamentos_financeiros
    (origem, canal, categoria, pedido_id, data_competencia, data_liberacao, status,
     valor_bruto, taxas, valor_liquido, sincronizado_em)
  values
    ('pedido', new.canal::text, 'venda', new.id, new.data_pedido, new.data_pedido,
     case when new.status = 'cancelado' then 'estornado' else 'a_receber' end,
     new.valor_total, new.taxas_canal, new.valor_total - coalesce(new.taxas_canal, 0), now())
  on conflict (pedido_id) where origem = 'pedido' do update set
    canal            = excluded.canal,
    data_competencia = excluded.data_competencia,
    data_liberacao   = case when lancamentos_financeiros.liberacao_editada
                            then lancamentos_financeiros.data_liberacao else excluded.data_liberacao end,
    status           = excluded.status,
    valor_bruto      = excluded.valor_bruto,
    taxas            = excluded.taxas,
    valor_liquido    = excluded.valor_liquido,
    sincronizado_em  = now(),
    updated_at       = now();
  return new;
end;
$$;

drop trigger if exists trg_lancamento_pedido on pedidos_venda;
create trigger trg_lancamento_pedido
  after insert or update of status, valor_total, taxas_canal, data_pedido, canal on pedidos_venda
  for each row execute function sync_lancamento_pedido();

-- pedidos já existentes sem ML (loja física / loja online)
insert into lancamentos_financeiros
  (origem, canal, categoria, pedido_id, data_competencia, data_liberacao, status,
   valor_bruto, taxas, valor_liquido, sincronizado_em)
select 'pedido', pv.canal::text, 'venda', pv.id, pv.data_pedido, pv.data_pedido,
       case when pv.status = 'cancelado' then 'estornado' else 'a_receber' end,
       pv.valor_total, pv.taxas_canal, pv.valor_total - coalesce(pv.taxas_canal, 0), now()
from pedidos_venda pv
where pv.ml_order_id is null
on conflict (pedido_id) where origem = 'pedido' do nothing;

-- ---------- cancelamento vindo do ML (só Edge Functions chamam) ----------
-- p_devolver_estoque = true  → usa a cancelar_pedido_venda de sempre (devolve o que foi baixado)
-- p_devolver_estoque = false → só tira do faturamento (status cancelado), estoque não muda
create or replace function registrar_cancelamento_ml(p_pedido_id uuid, p_devolver_estoque boolean)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status status_pedido;
  v_ml text;
begin
  select status, ml_order_id into v_status, v_ml from pedidos_venda where id = p_pedido_id for update;
  if v_status is null then raise exception 'Pedido não encontrado'; end if;
  if v_ml is null then raise exception 'Só pedidos do Mercado Livre'; end if;
  if v_status = 'cancelado' then return 'ja_cancelado'; end if;

  if p_devolver_estoque then
    perform cancelar_pedido_venda(p_pedido_id);
  else
    update pedidos_venda set status = 'cancelado', updated_at = now() where id = p_pedido_id;
  end if;

  update pedidos_venda
     set cancelado_ml_em = now(),
         cancelamento_estoque = case when p_devolver_estoque then 'devolvido' else 'nao_devolvido' end,
         observacao = concat_ws(' | ', nullif(observacao, ''),
                                'Cancelado no Mercado Livre (' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY') || ')' ||
                                case when p_devolver_estoque then ' — estoque devolvido' else ' — estoque não mexido' end)
   where id = p_pedido_id;
  return case when p_devolver_estoque then 'cancelado_com_devolucao' else 'cancelado_sem_devolucao' end;
end;
$$;

revoke all on function registrar_cancelamento_ml(uuid, boolean) from public, anon, authenticated;
grant execute on function registrar_cancelamento_ml(uuid, boolean) to service_role;

-- ---------- fila da Edge Function (novos + os que ainda podem mudar) ----------
create or replace function receber_fila_sync(p_limite integer default 40, p_desde timestamptz default null)
returns table (id uuid, canal text, ml_order_id text, status text, local_baixa text, novo boolean)
language sql
stable
security definer
set search_path = public
as $$
  (select pv.id, pv.canal::text, pv.ml_order_id, pv.status::text, pv.local_baixa_estoque::text, true
     from pedidos_venda pv
    where pv.ml_order_id is not null and pv.receber_sincronizado_em is null
      and (p_desde is null or pv.data_pedido >= p_desde)
    order by pv.data_pedido desc
    limit greatest(p_limite, 0))
  union all
  (select pv.id, pv.canal::text, pv.ml_order_id, pv.status::text, pv.local_baixa_estoque::text, false
     from pedidos_venda pv
    where pv.ml_order_id is not null
      and pv.receber_sincronizado_em < now() - interval '6 hours'
      and (p_desde is null or pv.data_pedido >= p_desde)
      and exists (select 1 from lancamentos_financeiros l
                   where l.pedido_id = pv.id
                     and (l.status in ('aguardando', 'a_receber')
                          or (l.status = 'recebido' and l.data_liberacao > now() - interval '30 days')))
    order by pv.receber_sincronizado_em
    limit greatest(p_limite, 0))
  limit greatest(p_limite, 0)
$$;

create or replace function receber_fila_contagem()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'novos', (select count(*) from pedidos_venda where ml_order_id is not null and receber_sincronizado_em is null),
    'para_atualizar', (select count(*) from pedidos_venda pv
                        where pv.ml_order_id is not null and pv.receber_sincronizado_em < now() - interval '6 hours'
                          and exists (select 1 from lancamentos_financeiros l where l.pedido_id = pv.id
                                       and (l.status in ('aguardando', 'a_receber')
                                            or (l.status = 'recebido' and l.data_liberacao > now() - interval '30 days')))))
$$;

revoke all on function receber_fila_sync(integer, timestamptz) from public, anon, authenticated;
revoke all on function receber_fila_contagem() from public, anon;
grant execute on function receber_fila_sync(integer, timestamptz) to service_role;
grant execute on function receber_fila_contagem() to service_role, authenticated;

-- ---------- base de consulta (usada pela lista, totais e gráfico) ----------
-- status efetivo: ML = o que o Mercado Pago diz; PDV/manual = pela data
-- (já passou da data de liberação → recebido).
create or replace function contas_receber_base(
  p_inicio     date    default null,
  p_fim        date    default null,
  p_canais     text[]  default null,
  p_status     text[]  default null,
  p_texto      text    default null,
  p_campo_data text    default 'liberacao',   -- 'liberacao' | 'venda'
  p_natureza   text    default 'receber'
)
returns table (
  id uuid, natureza text, origem text, canal text, categoria text,
  descricao text, produtos text, cliente text, pedido_id uuid, ml_order_id text,
  data_competencia timestamptz, data_liberacao timestamptz, mes_liberacao date,
  status text, ml_release_status text, ml_payment_status text, liberacao_editada boolean, parcelas integer,
  valor_bruto numeric, tarifa numeric, frete numeric, taxas numeric, outros_ajustes numeric,
  valor_reembolsado numeric, valor_liquido numeric, imposto numeric,
  custo numeric, custo_status text, nomes_sem_custo text, lucro numeric, observacao text
)
language sql
stable
security invoker
set search_path = public
as $$
  with lf as materialized (
    select l.*,
           case
             when l.origem = 'ml' or l.status in ('estornado', 'aguardando') then l.status
             when l.data_liberacao <= now() then 'recebido'
             else 'a_receber'
           end as status_ef,
           (case when p_campo_data = 'venda' then l.data_competencia else l.data_liberacao end
              at time zone 'America/Sao_Paulo')::date as data_ref
    from lancamentos_financeiros l
    where l.natureza = coalesce(p_natureza, 'receber')
      and (p_canais is null or cardinality(p_canais) = 0 or l.canal = any(p_canais))
  ),
  f as materialized (
    select * from lf
    where (p_inicio is null or data_ref >= p_inicio)
      and (p_fim is null or data_ref <= p_fim)
      and (p_status is null or cardinality(p_status) = 0 or status_ef = any(p_status))
  ),
  cu as materialized (select produto_id, custo_unitario from vw_custo_unitario),
  cp as materialized (
    select pi.pedido_id,
           sum(pi.quantidade * cu.custo_unitario) as custo,
           count(*) filter (where cu.custo_unitario is null) as itens_sem_custo,
           string_agg(coalesce(p.nome, pi.sku_ml_item, '?') ||
                      case when pi.quantidade <> 1 then ' ×' || rtrim(rtrim(pi.quantidade::text, '0'), '.') else '' end,
                      ', ' order by coalesce(p.nome, pi.sku_ml_item)) as produtos,
           string_agg(distinct coalesce(p.nome, 'SKU ' || pi.sku_ml_item, 'item sem produto'), ', ')
             filter (where cu.custo_unitario is null) as nomes_sem_custo,
           string_agg(coalesce(p.sku_interno, '') || ' ' || coalesce(pi.sku_ml_item, ''), ' ') as skus
    from pedido_itens pi
    left join produtos p on p.id = pi.produto_id
    left join cu on cu.produto_id = pi.produto_id
    where pi.pedido_id in (select f.pedido_id from f where f.pedido_id is not null)
    group by pi.pedido_id
  ),
  j as (
    select f.*,
           cp.custo as custo_pedido, cp.itens_sem_custo, cp.produtos, cp.nomes_sem_custo, cp.skus,
           pv.cliente_nome_avulso, pv.numero_pedido,
           -- pedido com mais de 1 pagamento: custo dividido pelo bruto de cada pagamento
           f.valor_bruto / nullif(sum(case when f.status_ef <> 'estornado' then f.valor_bruto end)
                                  over (partition by f.pedido_id), 0) as fatia
    from f
    left join cp on cp.pedido_id = f.pedido_id
    left join pedidos_venda pv on pv.id = f.pedido_id
  ),
  c as (
    select j.*,
           case
             when j.status_ef = 'estornado' then 'estornado'
             when j.categoria <> 'venda' then 'nao_aplica'
             when j.origem = 'manual' then case when j.custo_manual is null then 'sem_custo' else 'ok' end
             when j.custo_pedido is null and j.itens_sem_custo is null then 'sem_custo'   -- pedido sem itens
             when j.itens_sem_custo > 0 then 'sem_custo'
             else 'ok'
           end as cst
    from j
  )
  select c.id, c.natureza, c.origem, c.canal, c.categoria,
         coalesce(nullif(c.descricao, ''), c.produtos) as descricao,
         c.produtos,
         c.cliente_nome_avulso as cliente,
         c.pedido_id, c.ml_order_id,
         c.data_competencia, c.data_liberacao,
         date_trunc('month', c.data_liberacao at time zone 'America/Sao_Paulo')::date as mes_liberacao,
         c.status_ef as status, c.ml_release_status, c.ml_payment_status, c.liberacao_editada, c.parcelas,
         c.valor_bruto, c.tarifa, c.frete, c.taxas, c.outros_ajustes,
         c.valor_reembolsado, c.valor_liquido, c.imposto,
         case c.cst
           when 'estornado' then 0
           when 'ok' then case when c.origem = 'manual' then c.custo_manual
                               else round(c.custo_pedido * coalesce(c.fatia, 1), 2) end
           else null
         end as custo,
         c.cst as custo_status,
         case when c.cst = 'sem_custo' then coalesce(c.nomes_sem_custo, 'sem custo informado') end as nomes_sem_custo,
         case c.cst
           when 'estornado' then 0
           when 'ok' then c.valor_liquido - case when c.origem = 'manual' then c.custo_manual
                                                 else round(c.custo_pedido * coalesce(c.fatia, 1), 2) end
           else null
         end as lucro,
         c.observacao
  from c
  where p_texto is null or btrim(p_texto) = '' or
        concat_ws(' ', c.descricao, c.produtos, c.skus, c.cliente_nome_avulso, c.ml_order_id,
                  c.numero_pedido, c.observacao, c.canal) ilike
        '%' || replace(replace(replace(btrim(p_texto), '\', '\\'), '%', '\%'), '_', '\_') || '%'
$$;

-- lista paginada
create or replace function contas_receber_listar(
  p_inicio date default null, p_fim date default null, p_canais text[] default null,
  p_status text[] default null, p_texto text default null, p_campo_data text default 'liberacao',
  p_limite integer default 50, p_offset integer default 0
)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  with b as (select * from contas_receber_base(p_inicio, p_fim, p_canais, p_status, p_texto, p_campo_data, 'receber')),
  pag as (
    select * from b
    order by case when p_campo_data = 'venda' then b.data_competencia else b.data_liberacao end desc nulls first,
             b.data_competencia desc, b.id
    limit least(greatest(p_limite, 1), 500) offset greatest(p_offset, 0)
  )
  select jsonb_build_object(
    'total', (select count(*) from b),
    'linhas', coalesce((select jsonb_agg(to_jsonb(pag) order by
                                case when p_campo_data = 'venda' then pag.data_competencia else pag.data_liberacao end desc nulls first,
                                pag.data_competencia desc, pag.id) from pag), '[]'::jsonb))
$$;

-- totais do filtro
create or replace function contas_receber_resumo(
  p_inicio date default null, p_fim date default null, p_canais text[] default null,
  p_status text[] default null, p_texto text default null, p_campo_data text default 'liberacao'
)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'qtd',              count(*),
    'a_receber',        coalesce(sum(valor_liquido) filter (where status = 'a_receber'), 0),
    'recebido',         coalesce(sum(valor_liquido) filter (where status = 'recebido'), 0),
    'aguardando',       coalesce(sum(valor_liquido) filter (where status = 'aguardando'), 0),
    'estornado_bruto',  coalesce(sum(valor_bruto) filter (where status = 'estornado'), 0),
    'qtd_estornado',    count(*) filter (where status = 'estornado'),
    'bruto',            coalesce(sum(valor_bruto) filter (where status <> 'estornado'), 0),
    'liquido',          coalesce(sum(valor_liquido) filter (where status <> 'estornado'), 0),
    'custo',            coalesce(sum(custo) filter (where custo_status = 'ok'), 0),
    'lucro',            coalesce(sum(lucro) filter (where custo_status = 'ok'), 0),
    'lucro_a_receber',  coalesce(sum(lucro) filter (where custo_status = 'ok' and status = 'a_receber'), 0),
    'qtd_sem_custo',    count(*) filter (where custo_status = 'sem_custo'),
    'liquido_sem_custo',coalesce(sum(valor_liquido) filter (where custo_status = 'sem_custo'), 0)
  )
  from contas_receber_base(p_inicio, p_fim, p_canais, p_status, p_texto, p_campo_data, 'receber')
$$;

-- gráfico: por MÊS DE LIBERAÇÃO × canal (natureza preparada pra "pagar")
-- p_meses vazio → usa p_inicio/p_fim; com meses → só esses meses (ex: dez, ago, jan)
create or replace function contas_receber_mensal(
  p_inicio date default null, p_fim date default null, p_meses date[] default null,
  p_canais text[] default null, p_status text[] default null, p_texto text default null,
  p_natureza text default 'receber'
)
returns table (mes date, canal text, natureza text, liquido numeric, lucro numeric, qtd bigint,
               qtd_sem_custo bigint, liquido_sem_custo numeric)
language sql
stable
security invoker
set search_path = public
as $$
  select b.mes_liberacao, b.canal, b.natureza,
         sum(b.valor_liquido),
         coalesce(sum(b.lucro) filter (where b.custo_status = 'ok'), 0),
         count(*),
         count(*) filter (where b.custo_status = 'sem_custo'),
         coalesce(sum(b.valor_liquido) filter (where b.custo_status = 'sem_custo'), 0)
  from contas_receber_base(
         case when p_meses is null or cardinality(p_meses) = 0 then p_inicio else (select min(m) from unnest(p_meses) m) end,
         case when p_meses is null or cardinality(p_meses) = 0 then p_fim
              else ((select max(m) from unnest(p_meses) m) + interval '1 month' - interval '1 day')::date end,
         p_canais, p_status, p_texto, 'liberacao', p_natureza) b
  where b.mes_liberacao is not null
    and b.status <> 'estornado'
    and (p_meses is null or cardinality(p_meses) = 0
         or b.mes_liberacao = any (select date_trunc('month', m)::date from unnest(p_meses) m))
  group by b.mes_liberacao, b.canal, b.natureza
  order by b.mes_liberacao, b.canal
$$;

revoke all on function contas_receber_base(date, date, text[], text[], text, text, text) from public, anon;
revoke all on function contas_receber_listar(date, date, text[], text[], text, text, integer, integer) from public, anon;
revoke all on function contas_receber_resumo(date, date, text[], text[], text, text) from public, anon;
revoke all on function contas_receber_mensal(date, date, date[], text[], text[], text, text) from public, anon;
grant execute on function contas_receber_base(date, date, text[], text[], text, text, text) to authenticated, service_role;
grant execute on function contas_receber_listar(date, date, text[], text[], text, text, integer, integer) to authenticated, service_role;
grant execute on function contas_receber_resumo(date, date, text[], text[], text, text) to authenticated, service_role;
grant execute on function contas_receber_mensal(date, date, date[], text[], text[], text, text) to authenticated, service_role;

-- ---------- conferência: faturamento, líquido e estoque idênticos ----------
do $$
declare a record; d record;
begin
  select * into a from _antes;
  select (select count(*) from pedidos_venda) as n,
         (select count(*) filter (where status = 'confirmado') from pedidos_venda) as n_conf,
         (select coalesce(sum(valor_total) filter (where status = 'confirmado'), 0) from pedidos_venda) as fat,
         (select coalesce(sum(valor_liquido), 0) from pedidos_venda) as liq,
         (select coalesce(sum(quantidade), 0) from estoque_saldos) as estoque
    into d;
  if row(a.n, a.n_conf, a.fat, a.liq, a.estoque) is distinct from row(d.n, d.n_conf, d.fat, d.liq, d.estoque) then
    raise exception 'PARADO: faturamento/estoque mudou — nada foi aplicado. Mande isto pro Claude.';
  end if;
  -- todo pedido sem ML tem exatamente 1 lançamento, com o mesmo valor
  if exists (select 1 from pedidos_venda pv
             left join lancamentos_financeiros l on l.pedido_id = pv.id and l.origem = 'pedido'
             where pv.ml_order_id is null
               and (l.id is null or l.valor_bruto <> pv.valor_total)) then
    raise exception 'PARADO: pedido da loja sem lançamento correspondente. Nada foi aplicado.';
  end if;
end $$;

commit;

select 'ok — contas a receber criado; faturamento e estoque intactos' as status,
       (select count(*) from lancamentos_financeiros) as lancamentos_pdv_loja,
       (select coalesce(sum(valor_liquido), 0) from lancamentos_financeiros) as valor_pdv_loja,
       (select count(*) from pedidos_venda where ml_order_id is not null) as pedidos_ml_para_sincronizar;
