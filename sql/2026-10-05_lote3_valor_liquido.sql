-- ============================================================
-- ERP E-Factory — LOTE 3 (banco)
-- Valor LÍQUIDO do Mercado Livre AO LADO do faturamento (bruto).
--   • Só ADICIONA colunas novas e uma função nova.
--   • NÃO altera valor_total, frete, taxas, nem as funções de
--     faturamento (dashboard_faturamento / resumo_vendas_filtro).
--   • Não preenche nenhuma venda antiga (isso é o backfill, que
--     só roda quando você clicar no botão, depois de aprovar).
--
-- Cole TUDO no Supabase → SQL Editor → RUN.
-- ============================================================
begin;

-- Foto do faturamento ANTES (pra provar no fim que nada mudou)
create temp table _antes on commit drop as
  select count(*) as n, sum(valor_total) as total, sum(valor_produtos) as produtos,
         sum(valor_frete) as frete, sum(taxas_canal) as taxas
  from pedidos_venda;

alter table pedidos_venda
  add column if not exists valor_liquido          numeric(14,2),   -- o que entra de fato (Mercado Pago: net_received_amount)
  add column if not exists liquido_tarifa_ml      numeric(14,2),   -- tarifa de venda do ML (ml_sale_fee)
  add column if not exists liquido_frete_vendedor numeric(14,2),   -- frete pago pelo vendedor (shp_*)
  add column if not exists liquido_taxas_mp       numeric(14,2),   -- taxas do Mercado Pago (mp_*)
  add column if not exists liquido_status         text,            -- ok | estornado | reembolso_parcial | sem_pagamento | erro
  add column if not exists liquido_atualizado_em  timestamptz;

-- acha rápido as vendas ML que ainda não têm líquido
create index if not exists idx_pedidos_ml_sem_liquido
  on pedidos_venda(data_pedido) where ml_order_id is not null and valor_liquido is null;

-- Totais de líquido com os MESMOS filtros da tela (usa a mesma base do Lote 2)
create or replace function resumo_liquido_filtro(
  p_inicio timestamptz,
  p_fim timestamptz,
  p_canal text,
  p_produto uuid default null,
  p_texto text default null
)
returns table (liquido numeric, pedidos_com_liquido bigint, pedidos_ml_sem_liquido bigint, bruto_dos_com_liquido numeric)
language sql
stable
security invoker
set search_path = public
as $$
  select
    coalesce(sum(valor_liquido) filter (where status = 'confirmado' and valor_liquido is not null), 0)::numeric,
    count(*) filter (where status = 'confirmado' and valor_liquido is not null)::bigint,
    count(*) filter (where status = 'confirmado' and ml_order_id is not null and valor_liquido is null)::bigint,
    coalesce(sum(valor_total) filter (where status = 'confirmado' and valor_liquido is not null), 0)::numeric
  from filtrar_pedidos_venda(p_inicio, p_fim, p_canal, p_produto, p_texto)
$$;

grant execute on function resumo_liquido_filtro(timestamptz, timestamptz, text, uuid, text) to authenticated;

-- Conferência: faturamento continua idêntico
do $$
declare a record; d record;
begin
  select * into a from _antes;
  select count(*) as n, sum(valor_total) as total, sum(valor_produtos) as produtos,
         sum(valor_frete) as frete, sum(taxas_canal) as taxas into d
  from pedidos_venda;
  if row(a.n, a.total, a.produtos, a.frete, a.taxas) is distinct from row(d.n, d.total, d.produtos, d.frete, d.taxas) then
    raise exception 'PARADO: o faturamento mudou — nada foi aplicado. Mande isto pro Claude.';
  end if;
end $$;

commit;

select 'ok — colunas de líquido criadas, faturamento intacto' as status,
       (select sum(valor_total) from pedidos_venda where status = 'confirmado') as faturamento_total,
       (select count(*) from pedidos_venda where ml_order_id is not null and valor_liquido is null) as vendas_ml_sem_liquido;
