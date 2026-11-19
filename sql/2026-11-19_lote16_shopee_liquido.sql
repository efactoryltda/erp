-- ============================================================
-- ERP E-Factory — LOTE 16 — Shopee fase 2: taxas, líquido e Contas a receber (19/11/2026)
-- Fórmula confirmada com pedidos reais (get_escrow_detail):
--   repasse = preço de venda − comissão − taxa de serviço − taxa de proteção de frete (± ajustes)
-- Gravação feita pela Edge Function shopee-sync-liquido (service_role):
--   • colunas de líquido do pedido (as mesmas do ML na tela de Vendas)
--   • 1 lançamento por pedido em lancamentos_financeiros (origem 'shopee')
--     convenção igual à do ML: líquido = bruto − tarifa − frete − taxas − outros − reembolsado
--     liberado pela Shopee → 'recebido' na data da liberação; ainda não → 'aguardando';
--     cancelado/devolvido inteiro → 'estornado'
-- ============================================================
begin;

-- 1 lançamento por pedido Shopee
create unique index if not exists uq_lanc_shopee_pedido
  on lancamentos_financeiros (pedido_id) where origem = 'shopee';

-- ------------------------------------------------------------
-- Grava o líquido de UM pedido Shopee (idempotente)
-- p_dados: bruto, tarifa, frete, taxas, outros, reembolsado, liquido,
--          liberado_em (timestamptz|null), estornado (bool), liquido_status, resumo (jsonb)
-- ------------------------------------------------------------
create or replace function registrar_liquido_shopee(p_pedido_id uuid, p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_ped        pedidos_venda%rowtype;
  v_estornado  boolean;
  v_lib        timestamptz := nullif(p_dados->>'liberado_em', '')::timestamptz;
  v_status     text;
  v_bruto      numeric := round(coalesce((p_dados->>'bruto')::numeric, 0), 2);
  v_tarifa     numeric := round(coalesce((p_dados->>'tarifa')::numeric, 0), 2);
  v_frete      numeric := round(coalesce((p_dados->>'frete')::numeric, 0), 2);
  v_taxas      numeric := round(coalesce((p_dados->>'taxas')::numeric, 0), 2);
  v_outros     numeric := round(coalesce((p_dados->>'outros')::numeric, 0), 2);
  v_reemb      numeric := round(coalesce((p_dados->>'reembolsado')::numeric, 0), 2);
  v_liquido    numeric := round(coalesce((p_dados->>'liquido')::numeric, 0), 2);
  v_id         uuid;
begin
  select * into v_ped from pedidos_venda where id = p_pedido_id for update;
  if not found or v_ped.shopee_order_sn is null then
    raise exception 'Pedido Shopee % não encontrado', p_pedido_id;
  end if;

  v_estornado := coalesce((p_dados->>'estornado')::boolean, false) or v_ped.status = 'cancelado';
  if v_estornado then
    -- igual ao ML: estorno = todo o bruto reembolsado, líquido zero
    v_tarifa := 0; v_frete := 0; v_taxas := 0; v_outros := 0;
    v_reemb := v_bruto; v_liquido := 0;
  end if;

  v_status := case when v_estornado then 'estornado'
                   when v_lib is not null then 'recebido'
                   else 'aguardando' end;

  update pedidos_venda set
    valor_liquido          = v_liquido,
    liquido_tarifa_ml      = v_tarifa,
    liquido_frete_vendedor = v_frete,
    liquido_taxas_mp       = round(v_bruto - v_tarifa - v_frete - v_liquido, 2),  -- taxas + ajustes + reembolsos
    liquido_status         = case when v_estornado then 'estornado'
                                  else coalesce(nullif(p_dados->>'liquido_status', ''), 'ok') end,
    liquido_atualizado_em  = now()
  where id = p_pedido_id;

  insert into lancamentos_financeiros as l (
    natureza, origem, canal, categoria, pedido_id, data_competencia, data_liberacao, status,
    valor_bruto, tarifa, frete, taxas, outros_ajustes, valor_reembolsado, valor_liquido,
    observacao, dados_ml, sincronizado_em)
  values (
    'receber', 'shopee', 'shopee', 'venda', p_pedido_id, v_ped.data_pedido,
    case when v_estornado then null else v_lib end, v_status,
    v_bruto, v_tarifa, v_frete, v_taxas, v_outros, v_reemb, v_liquido,
    'Shopee ' || v_ped.shopee_order_sn, p_dados->'resumo', now())
  on conflict (pedido_id) where origem = 'shopee' do update set
    data_competencia  = excluded.data_competencia,
    -- data editada à mão na tela não é sobrescrita
    data_liberacao    = case when l.liberacao_editada and excluded.status <> 'estornado'
                             then l.data_liberacao else excluded.data_liberacao end,
    status            = case when l.liberacao_editada and excluded.status = 'aguardando' and l.data_liberacao is not null
                             then 'a_receber' else excluded.status end,
    valor_bruto       = excluded.valor_bruto,
    tarifa            = excluded.tarifa,
    frete             = excluded.frete,
    taxas             = excluded.taxas,
    outros_ajustes    = excluded.outros_ajustes,
    valor_reembolsado = excluded.valor_reembolsado,
    valor_liquido     = excluded.valor_liquido,
    observacao        = excluded.observacao,
    dados_ml          = excluded.dados_ml,
    sincronizado_em   = now(),
    updated_at        = now()
  returning id into v_id;

  return jsonb_build_object('lancamento_id', v_id, 'status', v_status, 'liquido', v_liquido);
end;
$$;

-- ------------------------------------------------------------
-- Fila: pedidos Shopee reais que ainda precisam de (re)consulta do repasse
--   sem lançamento | lançamento aguardando | cancelado no ERP mas lançamento não estornado
-- ------------------------------------------------------------
create or replace function fila_liquido_shopee(p_limite int default 40)
returns table(pedido_id uuid, order_sn text, valor_total numeric, status text, shopee_status text, tem_lancamento boolean)
language sql
stable
security definer
set search_path to 'public'
as $$
  select pv.id, pv.shopee_order_sn, pv.valor_total, pv.status::text, pv.shopee_status, l.id is not null
  from pedidos_venda pv
  left join lancamentos_financeiros l on l.pedido_id = pv.id and l.origem = 'shopee'
  where pv.shopee_order_sn is not null
    and pv.shopee_order_sn not like 'SANDBOX-%'
    and (l.id is null
         or l.status = 'aguardando'
         or (pv.status = 'cancelado' and l.status <> 'estornado'))
  order by (l.id is null) desc, pv.liquido_atualizado_em nulls first, pv.data_pedido
  limit greatest(1, least(coalesce(p_limite, 40), 200))
$$;

revoke all on function registrar_liquido_shopee(uuid, jsonb) from public, anon, authenticated;
revoke all on function fila_liquido_shopee(int) from public, anon, authenticated;
grant execute on function registrar_liquido_shopee(uuid, jsonb) to service_role;
grant execute on function fila_liquido_shopee(int) to service_role;

-- ------------------------------------------------------------
-- Tela de Vendas: "ainda sem líquido" passa a contar Shopee também
-- (mesma assinatura e mesmas colunas; só a contagem muda)
-- ------------------------------------------------------------
create or replace function resumo_liquido_filtro_v3(p_inicio timestamp with time zone, p_fim timestamp with time zone, p_canal text, p_produto uuid, p_texto text, p_modalidade text)
 returns table(liquido numeric, pedidos_com_liquido bigint, pedidos_ml_sem_liquido bigint, bruto_dos_com_liquido numeric)
 language sql
 stable
 set search_path to 'public'
as $function$
  select
    coalesce(sum(valor_liquido) filter (where status = 'confirmado' and valor_liquido is not null), 0)::numeric,
    count(*) filter (where status = 'confirmado' and valor_liquido is not null)::bigint,
    count(*) filter (where status = 'confirmado' and (ml_order_id is not null or shopee_order_sn is not null) and valor_liquido is null)::bigint,
    coalesce(sum(valor_total) filter (where status = 'confirmado' and valor_liquido is not null), 0)::numeric
  from filtrar_pedidos_venda_v3(p_inicio, p_fim, p_canal, p_produto, p_texto, p_modalidade)
$function$;

create or replace function resumo_liquido_filtro_v4(p_inicio timestamp with time zone, p_fim timestamp with time zone, p_canal text, p_produto uuid, p_texto text, p_modalidade text, p_nf text)
 returns table(liquido numeric, pedidos_com_liquido bigint, pedidos_ml_sem_liquido bigint, bruto_dos_com_liquido numeric)
 language sql
 stable
 set search_path to 'public'
as $function$
  select coalesce(sum(valor_liquido) filter (where status = 'confirmado' and valor_liquido is not null), 0)::numeric,
         count(*) filter (where status = 'confirmado' and valor_liquido is not null)::bigint,
         count(*) filter (where status = 'confirmado' and (ml_order_id is not null or shopee_order_sn is not null) and valor_liquido is null)::bigint,
         coalesce(sum(valor_total) filter (where status = 'confirmado' and valor_liquido is not null), 0)::numeric
    from filtrar_pedidos_venda_v4(p_inicio, p_fim, p_canal, p_produto, p_texto, p_modalidade, p_nf)
$function$;

commit;
