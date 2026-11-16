-- ============================================================================
-- Lote 13 — Dashboard gerencial (2026-11-16)
--
-- Cria UMA função nova, só de leitura: dashboard_gerencial(inicio, fim, serie_desde).
-- Não altera tabela, dado, nem nenhuma função existente (dashboard_faturamento
-- continua igual). Devolve um único JSON (sem risco do teto de ~1000 linhas),
-- com tudo somado dentro do banco e "dia" sempre no horário de Brasília.
--
-- Regras (as mesmas já usadas no resto do ERP):
--   * Faturamento = pedidos_venda.valor_total dos pedidos 'confirmado'.
--   * Líquido: Mercado Livre = valor_liquido (quando liquido_status é ok /
--     reembolso_parcial / estornado); loja física e loja online = o próprio
--     valor; Shopee = ainda sem líquido (fase 2 da integração) -> fica de fora
--     do líquido e do lucro, e a tela avisa.
--   * Custo = quantidade × vw_custo_unitario (ficha técnica, senão custo do
--     cadastro). Pedido com algum item sem custo fica fora do lucro (aviso).
--   * Lucro = líquido − custo, só dos pedidos que têm os dois.
--   * Valor em estoque = quantidade × produtos.custo_atual (igual ao Dashboard antigo).
--   * Contas a receber = contas_receber_base (mesma base da aba Contas a receber).
--
-- Confere sozinho no final: o faturamento do mês desta função tem que bater com
-- o de dashboard_faturamento(); se não bater, desfaz tudo ("PARADO: ...").
-- ============================================================================
begin;

create or replace function public.dashboard_gerencial(
  p_inicio date,
  p_fim date,
  p_serie_desde date default null
)
returns jsonb
language sql
stable
set search_path to 'public'
as $fn$
  with par as (
    select (now() at time zone 'America/Sao_Paulo')::date as hoje,
           least(coalesce(p_serie_desde, p_inicio), p_inicio,
                 (now() at time zone 'America/Sao_Paulo')::date - 8) as desde
  ),
  cu as materialized (select produto_id, custo_unitario from vw_custo_unitario),
  pv as materialized (
    select v.id,
           v.canal::text as canal,
           v.valor_total,
           coalesce(nullif(v.modalidade_envio, ''), 'envio_proprio') as envio,
           (v.data_pedido at time zone 'America/Sao_Paulo')::date as dia,
           case
             when v.canal::text like 'ml\_%' then
               case when v.liquido_status in ('ok', 'reembolso_parcial', 'estornado') then coalesce(v.valor_liquido, 0) end
             when v.canal::text = 'shopee' then null
             else v.valor_total
           end as liq,
           case when v.canal::text like 'ml\_%' then coalesce(v.liquido_tarifa_ml, 0) else 0 end as tarifa,
           case when v.canal::text like 'ml\_%' then coalesce(v.liquido_frete_vendedor, 0) else 0 end as frete,
           case when v.canal::text like 'ml\_%' then coalesce(v.liquido_taxas_mp, 0) else 0 end as taxas
    from pedidos_venda v, par
    where v.status = 'confirmado'
      and v.data_pedido >= (par.desde::timestamp at time zone 'America/Sao_Paulo')
      and v.data_pedido <  ((p_fim + 1)::timestamp at time zone 'America/Sao_Paulo')
  ),
  ci as materialized (
    select pi.pedido_id,
           sum(pi.quantidade * cu.custo_unitario) as custo,
           count(*) filter (where cu.custo_unitario is null) as sem_custo,
           sum(pi.subtotal) as sub
    from pedido_itens pi
    join pv on pv.id = pi.pedido_id
    left join cu on cu.produto_id = pi.produto_id
    group by pi.pedido_id
  ),
  ped as materialized (
    select pv.*, ci.custo, ci.sub,
           (ci.pedido_id is not null and ci.sem_custo = 0) as tem_custo,
           (pv.liq is not null) as tem_liq
    from pv left join ci on ci.pedido_id = pv.id
  ),
  serie as (
    select dia, canal,
           sum(valor_total) as f,
           count(*) as p,
           coalesce(sum(valor_total) filter (where tem_liq), 0) as fl,
           coalesce(sum(liq) filter (where tem_liq), 0) as l,
           coalesce(sum(valor_total) filter (where tem_liq and tem_custo), 0) as fc,
           coalesce(sum(liq) filter (where tem_liq and tem_custo), 0) as lc,
           coalesce(sum(custo) filter (where tem_liq and tem_custo), 0) as cc,
           coalesce(sum(tarifa) filter (where tem_liq and tem_custo), 0) as tc,
           coalesce(sum(frete) filter (where tem_liq and tem_custo), 0) as frc,
           coalesce(sum(taxas) filter (where tem_liq and tem_custo), 0) as txc,
           count(*) filter (where not tem_custo) as nsc,
           coalesce(sum(valor_total) filter (where not tem_custo), 0) as fsc,
           count(*) filter (where not tem_liq) as nsl,
           coalesce(sum(valor_total) filter (where not tem_liq), 0) as fsl
    from ped
    group by dia, canal
  ),
  prod as (
    select coalesce(pr.nome, 'SKU ' || pi.sku_ml_item, 'Item sem produto') as nome,
           pr.sku_interno as sku,
           ped.canal,
           sum(pi.quantidade) as q,
           sum(pi.subtotal) as f,
           coalesce(sum(pi.subtotal) filter (where ped.tem_liq and ped.tem_custo), 0) as fm,
           coalesce(sum(ped.liq * pi.subtotal / nullif(ped.sub, 0)) filter (where ped.tem_liq and ped.tem_custo), 0) as lm,
           coalesce(sum(pi.quantidade * cu.custo_unitario) filter (where ped.tem_liq and ped.tem_custo), 0) as cm
    from pedido_itens pi
    join ped on ped.id = pi.pedido_id
    left join produtos pr on pr.id = pi.produto_id
    left join cu on cu.produto_id = pi.produto_id
    where ped.dia between p_inicio and p_fim
    group by 1, 2, 3
  ),
  envio as (
    select envio, canal, count(*) as p, sum(valor_total) as f
    from ped
    where dia between p_inicio and p_fim
    group by 1, 2
  ),
  -- ---------- estoque (posição de agora) ----------
  saldo as (
    select s.produto_id,
           sum(s.quantidade) as total,
           sum(s.quantidade) filter (where s.local::text <> 'materia_prima') as vendavel
    from estoque_saldos s
    group by s.produto_id
  ),
  est_local as (
    select s.local::text as local, sum(coalesce(s.quantidade, 0) * coalesce(p.custo_atual, 0)) as valor
    from estoque_saldos s join produtos p on p.id = s.produto_id
    group by 1
  ),
  abaixo as (
    select p.nome, p.sku_interno as sku, coalesce(sa.total, 0) as total, coalesce(p.estoque_minimo, 0) as minimo
    from produtos p left join saldo sa on sa.produto_id = p.id
    where p.ativo and coalesce(sa.total, 0) < coalesce(p.estoque_minimo, 0)
  ),
  v30 as (
    select pi.produto_id, sum(pi.quantidade) as q
    from pedido_itens pi
    join pedidos_venda v on v.id = pi.pedido_id, par
    where v.status = 'confirmado' and pi.produto_id is not null
      and v.data_pedido >= ((par.hoje - 30)::timestamp at time zone 'America/Sao_Paulo')
      and v.data_pedido <  (par.hoje::timestamp at time zone 'America/Sao_Paulo')
    group by pi.produto_id
  ),
  cobertura as (
    select p.nome, p.sku_interno as sku,
           greatest(coalesce(sa.vendavel, 0), 0) as saldo,
           round(v30.q / 30.0, 2) as vd,
           round(greatest(coalesce(sa.vendavel, 0), 0) / (v30.q / 30.0), 1) as dias
    from v30
    join produtos p on p.id = v30.produto_id
    left join saldo sa on sa.produto_id = p.id
    where p.ativo and p.tipo::text = 'produto_acabado' and v30.q > 0
    order by 5, 4 desc, 1
    limit 8
  ),
  -- ---------- contas a receber (mesma base da aba) ----------
  cr as materialized (
    select b.valor_liquido, b.status, b.vencido,
           (b.data_liberacao at time zone 'America/Sao_Paulo')::date as d
    from contas_receber_base(null, null, null, null, null, 'liberacao', 'receber', null) b
    where b.status = 'a_receber'
  ),
  cr_sem as (
    select least(greatest((cr.d - par.hoje) / 7, 0), 4) as k, sum(cr.valor_liquido) as v, count(*) as n
    from cr, par
    where not coalesce(cr.vencido, false)
    group by 1
  ),
  -- ---------- anúncios (Mercado Ads) ----------
  ads as (
    select a.canal::text as canal, sum(a.custo) as custo, sum(a.vendas_totais) as vendas,
           sum(a.cliques) as cliques, sum(a.impressoes) as impressoes
    from ml_ads_metricas_diarias a
    where a.data between p_inicio and p_fim
    group by 1
  )
  select jsonb_build_object(
    'hoje', (select hoje from par),
    'agora', to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI'),
    'inicio', p_inicio, 'fim', p_fim, 'serie_desde', (select desde from par),
    'primeiro_pedido', (select min((data_pedido at time zone 'America/Sao_Paulo')::date) from pedidos_venda where status = 'confirmado'),
    'serie', coalesce((select jsonb_agg(jsonb_build_object(
        'd', dia, 'c', canal, 'f', f, 'p', p, 'fl', fl, 'l', l, 'fc', fc, 'lc', lc, 'cc', cc,
        'tc', tc, 'frc', frc, 'txc', txc, 'nsc', nsc, 'fsc', fsc, 'nsl', nsl, 'fsl', fsl) order by dia, canal) from serie), '[]'::jsonb),
    'produtos', coalesce((select jsonb_agg(jsonb_build_object(
        'n', nome, 'sku', sku, 'c', canal, 'q', q, 'f', f, 'fm', fm, 'lm', lm, 'cm', cm)) from prod), '[]'::jsonb),
    'envio', coalesce((select jsonb_agg(jsonb_build_object('e', envio, 'c', canal, 'p', p, 'f', f)) from envio), '[]'::jsonb),
    'estoque', jsonb_build_object(
      'locais', coalesce((select jsonb_object_agg(local, valor) from est_local), '{}'::jsonb),
      'abaixo', coalesce((select jsonb_agg(jsonb_build_object('n', nome, 'sku', sku, 'total', total, 'minimo', minimo) order by nome) from abaixo), '[]'::jsonb),
      'cobertura', coalesce((select jsonb_agg(jsonb_build_object('n', nome, 'sku', sku, 'saldo', saldo, 'vd', vd, 'dias', dias) order by dias, vd desc, nome) from cobertura), '[]'::jsonb)
    ),
    'receber', jsonb_build_object(
      'a_receber', coalesce((select sum(valor_liquido) from cr), 0),
      'prox7', coalesce((select sum(cr.valor_liquido) from cr, par where not coalesce(cr.vencido, false) and cr.d <= par.hoje + 6), 0),
      'qtd_vencido', (select count(*) from cr where coalesce(vencido, false)),
      'valor_vencido', coalesce((select sum(valor_liquido) from cr where coalesce(vencido, false)), 0),
      'semanas', coalesce((select jsonb_agg(jsonb_build_object('k', k, 'v', v, 'n', n) order by k) from cr_sem), '[]'::jsonb)
    ),
    'ads', jsonb_build_object(
      'ate', (select max(data) from ml_ads_metricas_diarias),
      'contas', coalesce((select jsonb_agg(jsonb_build_object('c', canal, 'custo', custo, 'vendas', vendas, 'cliques', cliques, 'impressoes', impressoes) order by canal) from ads), '[]'::jsonb)
    ),
    'pend', jsonb_build_object(
      'perguntas', (select count(*) from ml_perguntas_abertas),
      'pergunta_mais_antiga', (select min(data_pergunta) from ml_perguntas_abertas),
      'promo_vencendo', (select count(*) from ml_promocoes_ativas where data_fim is not null and data_fim <= now() + interval '3 days'),
      'sem_custo', (select count(*) from produtos p join cu on cu.produto_id = p.id where p.ativo and p.tipo::text = 'produto_acabado' and cu.custo_unitario is null),
      'ops', (select count(*) from ordens_producao where status::text = 'em_producao'),
      'shopee_nf', (select count(*) from pedidos_venda where status = 'confirmado' and shopee_status = 'INVOICE_PENDING'),
      'itens_sem_produto', (select count(*) from pedido_itens pi join pedidos_venda v on v.id = pi.pedido_id where v.status = 'confirmado' and pi.produto_id is null),
      'ml_sem_liquido', (select count(*) from pedidos_venda v where v.status = 'confirmado' and v.canal::text like 'ml\_%'
                          and (v.liquido_status is null or v.liquido_status not in ('ok', 'reembolso_parcial', 'estornado')))
    )
  )
$fn$;

revoke all on function public.dashboard_gerencial(date, date, date) from public, anon;
grant execute on function public.dashboard_gerencial(date, date, date) to authenticated, service_role;

-- ---------- conferência: faturamento do mês tem que bater com o Dashboard antigo ----------
do $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_mes date := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
  v_antigo numeric; v_ped_antigo integer; v_novo numeric; v_ped_novo numeric;
begin
  select fat_mes, pedidos_mes into v_antigo, v_ped_antigo from dashboard_faturamento();
  select coalesce(sum((x->>'f')::numeric), 0), coalesce(sum((x->>'p')::numeric), 0)
    into v_novo, v_ped_novo
  from jsonb_array_elements(dashboard_gerencial(v_mes, v_hoje, v_mes)->'serie') x
  where (x->>'d')::date >= v_mes;
  if abs(v_antigo - v_novo) > 0.01 or v_ped_antigo <> v_ped_novo then
    raise exception 'PARADO: faturamento do mês não bate (antigo % / % pedidos, novo % / % pedidos)', v_antigo, v_ped_antigo, v_novo, v_ped_novo;
  end if;
  raise notice 'OK: faturamento do mês % em % pedidos — igual nas duas funções', v_novo, v_ped_novo;
end $$;

commit;
