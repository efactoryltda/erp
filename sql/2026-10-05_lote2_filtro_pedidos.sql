-- ============================================================
-- ERP E-Factory — LOTE 2 (banco)
-- Filtro de pedidos por PRODUTO e por TEXTO (cliente, nº do
-- pedido ML ou SKU). Só ADICIONA funções novas — não altera
-- nenhuma função, tabela ou dado existente.
--
-- Cole TUDO no Supabase → SQL Editor → RUN.
-- No fim ele confere sozinho que, sem filtro de produto/texto,
-- a função nova dá EXATAMENTE os mesmos números da função atual
-- (resumo_vendas_filtro). Se não der, desfaz tudo e mostra erro.
-- ============================================================
begin;

-- Base única de filtro (mesmas regras de data/canal usadas na tela)
create or replace function filtrar_pedidos_venda(
  p_inicio timestamptz,
  p_fim timestamptz,
  p_canal text,
  p_produto uuid default null,
  p_texto text default null
)
returns setof pedidos_venda
language sql
stable
security invoker          -- respeita as mesmas permissões (RLS) da tela
set search_path = public
as $$
  with t as (
    -- escapa % e _ pra busca ser literal
    select nullif(btrim(replace(replace(replace(coalesce(p_texto, ''), '\', '\\'), '%', '\%'), '_', '\_')), '') as txt
  )
  select pv.*
  from pedidos_venda pv, t
  where (p_inicio is null or pv.data_pedido >= p_inicio)
    and (p_fim is null or pv.data_pedido < p_fim)
    and (p_canal is null or pv.canal::text = p_canal)
    and (p_produto is null or exists (
          select 1 from pedido_itens pi where pi.pedido_id = pv.id and pi.produto_id = p_produto))
    and (t.txt is null
         or pv.cliente_nome_avulso ilike '%' || t.txt || '%'
         or pv.ml_order_id ilike '%' || t.txt || '%'
         or pv.numero_pedido ilike '%' || t.txt || '%'
         or exists (
              select 1 from pedido_itens pi
              left join produtos p on p.id = pi.produto_id
              where pi.pedido_id = pv.id
                and (pi.sku_ml_item ilike '%' || t.txt || '%'
                     or p.sku_interno ilike '%' || t.txt || '%'
                     or p.nome ilike '%' || t.txt || '%')))
$$;

-- IDs da página atual (mesma ordem da tela: mais recente primeiro, desempate por id)
create or replace function listar_pedidos_filtro_ids(
  p_inicio timestamptz,
  p_fim timestamptz,
  p_canal text,
  p_produto uuid,
  p_texto text,
  p_limite int,
  p_offset int
)
returns setof uuid
language sql
stable
security invoker
set search_path = public
as $$
  select id from filtrar_pedidos_venda(p_inicio, p_fim, p_canal, p_produto, p_texto)
  order by data_pedido desc, id desc
  limit greatest(p_limite, 0) offset greatest(p_offset, 0)
$$;

-- Totais do filtro (mesmas 3 colunas da resumo_vendas_filtro)
create or replace function resumo_vendas_filtro_v2(
  p_inicio timestamptz,
  p_fim timestamptz,
  p_canal text,
  p_produto uuid default null,
  p_texto text default null
)
returns table (total_pedidos bigint, pedidos_confirmados bigint, faturamento numeric)
language sql
stable
security invoker
set search_path = public
as $$
  select count(*)::bigint,
         count(*) filter (where status = 'confirmado')::bigint,
         coalesce(sum(valor_total) filter (where status = 'confirmado'), 0)::numeric
  from filtrar_pedidos_venda(p_inicio, p_fim, p_canal, p_produto, p_texto)
$$;

grant execute on function filtrar_pedidos_venda(timestamptz, timestamptz, text, uuid, text) to authenticated;
grant execute on function listar_pedidos_filtro_ids(timestamptz, timestamptz, text, uuid, text, int, int) to authenticated;
grant execute on function resumo_vendas_filtro_v2(timestamptz, timestamptz, text, uuid, text) to authenticated;

-- índice pro filtro por produto
create index if not exists idx_pedido_itens_produto on pedido_itens(produto_id);


-- ------------------------------------------------------------
-- CONFERÊNCIA: sem produto/texto, a nova tem que bater 100% com a atual
-- ------------------------------------------------------------
do $$
declare
  casos text[][] := array[
    array[null, null, null],
    array[null, null, 'ml_conta1'],
    array[null, null, 'ml_conta3'],
    array[null, null, 'loja_fisica'],
    array['2026-09-01T03:00:00Z', '2026-10-01T03:00:00Z', null],
    array['2026-08-15T03:00:00Z', '2026-09-15T03:00:00Z', 'ml_conta2']
  ];
  v1 record;
  v2 record;
begin
  for i in 1 .. array_length(casos, 1) loop
    -- literais sem tipo: servem pra qualquer tipo de parâmetro que a função atual use
    execute format('select total_pedidos::bigint as a, pedidos_confirmados::bigint as b, faturamento::numeric as c
                      from resumo_vendas_filtro(p_inicio => %L, p_fim => %L, p_canal => %L)',
                   casos[i][1], casos[i][2], casos[i][3])
      into v1;
    select total_pedidos as a, pedidos_confirmados as b, faturamento as c into v2
      from resumo_vendas_filtro_v2(casos[i][1]::timestamptz, casos[i][2]::timestamptz, casos[i][3]);
    if v1.a is distinct from v2.a or v1.b is distinct from v2.b or round(v1.c, 2) is distinct from round(v2.c, 2) then
      raise exception 'PARADO: caso % não bate (atual: % / % / %, nova: % / % / %). Nada foi aplicado — mande isto pro Claude.',
        i, v1.a, v1.b, v1.c, v2.a, v2.b, v2.c;
    end if;
  end loop;
end $$;

commit;

-- Resultado de conferência (exemplo: todos os pedidos, sem filtro)
select 'ok — funções criadas e conferidas' as status, * from resumo_vendas_filtro_v2(null, null, null);
