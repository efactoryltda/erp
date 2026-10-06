-- ============================================================
-- ERP E-Factory — LOTE 4d — Contas a receber: venda CANCELADA no ML
-- conta como ESTORNADA (sai do a receber e do lucro) mesmo enquanto o
-- Mercado Pago ainda não registrou o estorno do pagamento.
--   • Só recria a função contas_receber_base (mesmos parâmetros e colunas).
--   • Não mexe em tabela, faturamento nem estoque.
--   • Confere sozinho: a função atual tem que ser a do Lote 4c e a única
--     diferença nos totais tem que ser exatamente essas vendas.
-- Cole TUDO no Supabase → SQL Editor → RUN.
-- ============================================================
begin;

do $$
declare v text;
begin
  select md5(regexp_replace(p.prosrc, '\s', '', 'g')) into v
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'contas_receber_base';
  if v is distinct from 'a0affc6e9ffee91386ddf91f5f9083a9' then
    raise exception 'PARADO: contas_receber_base no banco não é a do Lote 4c (%). Nada foi aplicado.', v;
  end if;
end $$;

create temp table _antes on commit drop as
  select (contas_receber_resumo(null, null, null, null, null, 'liberacao', null)->>'liquido')::numeric as liq,
         (contas_receber_resumo(null, null, null, null, null, 'liberacao', null)->>'qtd_estornado')::int as qtd_est,
         (select coalesce(sum(l.valor_liquido), 0) from lancamentos_financeiros l
            join pedidos_venda pv on pv.id = l.pedido_id
           where l.origem = 'ml' and pv.status = 'cancelado' and l.status <> 'estornado') as liq_afetado,
         (select count(*) from lancamentos_financeiros l
            join pedidos_venda pv on pv.id = l.pedido_id
           where l.origem = 'ml' and pv.status = 'cancelado' and l.status <> 'estornado')::int as qtd_afetada,
         (select coalesce(sum(valor_total) filter (where status = 'confirmado'), 0) from pedidos_venda) as fat;

create or replace function contas_receber_base(
  p_inicio     date    default null,
  p_fim        date    default null,
  p_canais     text[]  default null,
  p_status     text[]  default null,
  p_texto      text    default null,
  p_campo_data text    default 'liberacao',   -- 'liberacao' | 'venda'
  p_natureza   text    default 'receber',
  p_meses      date[]  default null          -- meses soltos (1º dia de cada mês), pela data escolhida
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
             -- Lote 4d: venda que o ML cancelou conta como estornada mesmo antes do
             -- Mercado Pago registrar o estorno do pagamento
             when l.origem = 'ml' and pvs.status = 'cancelado' then 'estornado'
             when l.origem = 'ml' or l.status in ('estornado', 'aguardando') then l.status
             when l.data_liberacao <= now() then 'recebido'
             else 'a_receber'
           end as status_ef,
           (case when p_campo_data = 'venda' then l.data_competencia else l.data_liberacao end
              at time zone 'America/Sao_Paulo')::date as data_ref
    from lancamentos_financeiros l
    left join pedidos_venda pvs on pvs.id = l.pedido_id
    where l.natureza = coalesce(p_natureza, 'receber')
      and (p_canais is null or cardinality(p_canais) = 0 or l.canal = any(p_canais))
  ),
  f as materialized (
    select * from lf
    where (p_inicio is null or data_ref >= p_inicio)
      and (p_fim is null or data_ref <= p_fim)
      and (p_status is null or cardinality(p_status) = 0 or status_ef = any(p_status))
      and (p_meses is null or cardinality(p_meses) = 0
           or date_trunc('month', data_ref)::date = any (select date_trunc('month', m)::date from unnest(p_meses) m))
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

do $$
declare a record; liq numeric; qtd int; fat numeric;
begin
  select * into a from _antes;
  liq := (contas_receber_resumo(null, null, null, null, null, 'liberacao', null)->>'liquido')::numeric;
  qtd := (contas_receber_resumo(null, null, null, null, null, 'liberacao', null)->>'qtd_estornado')::int;
  select coalesce(sum(valor_total) filter (where status = 'confirmado'), 0) into fat from pedidos_venda;
  if liq <> a.liq - a.liq_afetado or qtd <> a.qtd_est + a.qtd_afetada or fat <> a.fat then
    raise exception 'PARADO: diferença inesperada (líquido % → %, afetado %; estornados % → %). Nada foi aplicado.',
      a.liq, liq, a.liq_afetado, a.qtd_est, qtd;
  end if;
end $$;

commit;

select 'ok — venda cancelada no ML agora conta como estornada' as status,
       (select qtd_afetada from (select count(*)::int as qtd_afetada from lancamentos_financeiros l
          join pedidos_venda pv on pv.id = l.pedido_id
         where l.origem = 'ml' and pv.status = 'cancelado' and l.status <> 'estornado') x) as lancamentos_afetados,
       contas_receber_resumo(null, null, null, null, null, 'liberacao', null)->>'liquido' as liquido_total;
