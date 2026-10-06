-- ============================================================
-- ERP E-Factory — LOTE 4c — Contas a receber: filtro por MESES SOLTOS
-- (ex: dezembro, agosto e janeiro) em toda a tela (lista, totais, gráfico).
-- Só recria as funções de consulta do Lote 4 com o parâmetro p_meses.
-- Não mexe em tabela nenhuma, nem em faturamento/estoque.
-- ============================================================
begin;

drop function if exists contas_receber_listar(date, date, text[], text[], text, text, integer, integer);
drop function if exists contas_receber_resumo(date, date, text[], text[], text, text);
drop function if exists contas_receber_mensal(date, date, date[], text[], text[], text, text);
drop function if exists contas_receber_base(date, date, text[], text[], text, text, text);

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

-- lista paginada
create or replace function contas_receber_listar(
  p_inicio date default null, p_fim date default null, p_canais text[] default null,
  p_status text[] default null, p_texto text default null, p_campo_data text default 'liberacao',
  p_limite integer default 50, p_offset integer default 0, p_meses date[] default null
)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  with b as (select * from contas_receber_base(p_inicio, p_fim, p_canais, p_status, p_texto, p_campo_data, 'receber', p_meses)),
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
  p_status text[] default null, p_texto text default null, p_campo_data text default 'liberacao',
  p_meses date[] default null
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
  from contas_receber_base(p_inicio, p_fim, p_canais, p_status, p_texto, p_campo_data, 'receber', p_meses)
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
         p_canais, p_status, p_texto, 'liberacao', p_natureza, p_meses) b
  where b.mes_liberacao is not null
    and b.status <> 'estornado'
    and (p_meses is null or cardinality(p_meses) = 0
         or b.mes_liberacao = any (select date_trunc('month', m)::date from unnest(p_meses) m))
  group by b.mes_liberacao, b.canal, b.natureza
  order by b.mes_liberacao, b.canal
$$;

revoke all on function contas_receber_base(date, date, text[], text[], text, text, text, date[]) from public, anon;
revoke all on function contas_receber_listar(date, date, text[], text[], text, text, integer, integer, date[]) from public, anon;
revoke all on function contas_receber_resumo(date, date, text[], text[], text, text, date[]) from public, anon;
revoke all on function contas_receber_mensal(date, date, date[], text[], text[], text, text) from public, anon;
grant execute on function contas_receber_base(date, date, text[], text[], text, text, text, date[]) to authenticated, service_role;
grant execute on function contas_receber_listar(date, date, text[], text[], text, text, integer, integer, date[]) to authenticated, service_role;
grant execute on function contas_receber_resumo(date, date, text[], text[], text, text, date[]) to authenticated, service_role;
grant execute on function contas_receber_mensal(date, date, date[], text[], text[], text, text) to authenticated, service_role;


-- conferência: com os mesmos filtros, resumo antigo = novo (sem meses) e soma por mês = total
do $$
declare v_tot numeric; v_mes numeric;
begin
  select (contas_receber_resumo(null, null, null, array['a_receber','recebido'], null, 'liberacao', null)->>'liquido')::numeric into v_tot;
  select coalesce(sum(liquido), 0) into v_mes from contas_receber_mensal(null, null, null, null, array['a_receber','recebido'], null, 'receber');
  if v_tot is distinct from v_mes then
    raise exception 'PARADO: total (%) diferente da soma por mês (%). Nada foi aplicado.', v_tot, v_mes;
  end if;
end $$;

commit;

select 'ok — filtro por meses soltos criado' as status,
       contas_receber_resumo(null, null, null, null, null, 'liberacao',
         array[date_trunc('month', now() at time zone 'America/Sao_Paulo')::date]) as resumo_mes_atual;
