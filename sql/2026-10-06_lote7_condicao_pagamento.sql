-- ============================================================
-- ERP E-Factory — LOTE 7 — CONDIÇÃO DE PAGAMENTO (venda física)
--   • Tabela condicoes_pagamento (À vista, 30 dias, 30/60, 30/60/90,
--     Entrada 30% + 30 dias — dá pra cadastrar outras pela tela).
--   • Venda do PDV gera PARCELAS no contas a receber (antes: 1 lançamento).
--     Parcela na data da venda (à vista / entrada) já nasce RECEBIDA;
--     as futuras ficam "a receber" e só viram "recebido" com a baixa
--     (botão "Recebi"). Vencida e não recebida → aparece como VENCIDA.
--   • Forma de pagamento (Pix, dinheiro, cartão…) opcional, por parcela.
--   • Pedido cancelado → parcelas abertas estornadas; recebidas ficam com
--     aviso de devolução. Valor do pedido mudou → só as abertas recalculam
--     (pedido de 1 parcela só acompanha o valor, como antes).
--   • As 26 vendas físicas que já existem viram "à vista, 1 parcela" com o
--     MESMO status que a tela mostra hoje (recebido se a data já passou).
--   • Faturamento NÃO muda.
-- Confere sozinho: faturamento e estoque iguais; resumo e gráfico do
-- contas a receber IGUAIS antes/depois; teste completo de venda 30/70,
-- baixa, vencida, cancelamento e mudança de valor (tudo desfeito no fim).
-- Cole TUDO no Supabase → SQL Editor → RUN ("Run without RLS" se avisar).
-- ============================================================
begin;

do $$
declare v text; t text;
begin
  select md5(regexp_replace(p.prosrc, '\s', '', 'g')) into v
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'contas_receber_base';
  select md5(regexp_replace(p.prosrc, '\s', '', 'g')) into t
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'sync_lancamento_pedido';
  if v is distinct from 'b4d9a808b8211751fc75ff74eca67295' or t is distinct from '22eb1cd92b93f69c751068cd042f63e6' then
    raise exception 'PARADO: funções do contas a receber mudaram desde o Lote 4d (base %, trigger %). Nada foi aplicado.', v, t;
  end if;
end $$;

-- ---------- foto ANTES ----------
create temp table _antes on commit drop as
  select (select coalesce(sum(valor_total) filter (where status = 'confirmado'), 0) from pedidos_venda) as fat,
         (select count(*) from pedidos_venda) as n_ped,
         (select coalesce(sum(quantidade), 0) from estoque_saldos) as estoque,
         (select count(*) from lancamentos_financeiros) as n_lanc,
         contas_receber_resumo(null, null, null, null, null, 'liberacao', null) as resumo,
         contas_receber_resumo(null, null, null, array['a_receber','recebido'], null, 'liberacao', null) as resumo2,
         (select jsonb_agg(jsonb_build_object('m', mes, 'c', canal, 'l', liquido, 'u', lucro, 'q', qtd) order by mes, canal)
            from contas_receber_mensal(null, null, null, null, array['a_receber','recebido'], null, 'receber')) as mensal;

-- ---------- condições de pagamento ----------
create or replace function condicao_parcelas_valida(p jsonb)
returns boolean language sql immutable as $$
  select jsonb_typeof(p) = 'array' and jsonb_array_length(p) between 1 and 24
     and not exists (select 1 from jsonb_array_elements(p) e
                     where coalesce(jsonb_typeof(e->'pct'), '') <> 'number' or coalesce(jsonb_typeof(e->'dias'), '') <> 'number'
                        or (e->>'pct')::numeric <= 0 or (e->>'dias')::numeric < 0)
     and abs((select sum((e->>'pct')::numeric) from jsonb_array_elements(p) e) - 100) < 0.005
$$;

create table if not exists condicoes_pagamento (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null unique,
  parcelas   jsonb not null check (condicao_parcelas_valida(parcelas)),   -- [{"pct":30,"dias":0},{"pct":70,"dias":30}]
  ativo      boolean not null default true,
  ordem      integer not null default 100,
  created_at timestamptz not null default now()
);
alter table condicoes_pagamento enable row level security;
drop policy if exists cond_select on condicoes_pagamento;
drop policy if exists cond_insert on condicoes_pagamento;
drop policy if exists cond_update on condicoes_pagamento;
create policy cond_select on condicoes_pagamento for select to authenticated using (true);
create policy cond_insert on condicoes_pagamento for insert to authenticated with check (true);
create policy cond_update on condicoes_pagamento for update to authenticated using (true) with check (true);
revoke all on condicoes_pagamento from anon;
grant select, insert, update on condicoes_pagamento to authenticated;

insert into condicoes_pagamento (nome, parcelas, ordem) values
  ('À vista',                 '[{"pct":100,"dias":0}]', 1),
  ('30 dias',                 '[{"pct":100,"dias":30}]', 2),
  ('30/60',                   '[{"pct":50,"dias":30},{"pct":50,"dias":60}]', 3),
  ('30/60/90',                '[{"pct":33.34,"dias":30},{"pct":33.33,"dias":60},{"pct":33.33,"dias":90}]', 4),
  ('Entrada 30% + 30 dias',   '[{"pct":30,"dias":0},{"pct":70,"dias":30}]', 5)
on conflict (nome) do nothing;

-- ---------- colunas novas (só acréscimo) ----------
alter table pedidos_venda
  add column if not exists condicao_pagamento text,   -- nome da condição usada na venda
  add column if not exists forma_pagamento    text;   -- Pix, Dinheiro, Cartão…
alter table lancamentos_financeiros
  add column if not exists parcela_num     integer,
  add column if not exists parcela_total   integer,
  add column if not exists recebido_em     timestamptz,
  add column if not exists forma_pagamento text;

-- vendas físicas que já existem: 1 parcela à vista, mesmo status que a tela mostra hoje
update lancamentos_financeiros
   set parcela_num = 1, parcela_total = 1,
       status = case when status = 'estornado' then 'estornado'
                     when data_liberacao <= now() then 'recebido' else 'a_receber' end,
       recebido_em = case when status <> 'estornado' and data_liberacao <= now() then data_liberacao end,
       updated_at = now()
 where origem = 'pedido';

drop index if exists uq_lanc_pedido;
create unique index if not exists uq_lanc_pedido_parcela
  on lancamentos_financeiros(pedido_id, parcela_num) where origem = 'pedido';
create index if not exists idx_lanc_vencidas
  on lancamentos_financeiros(data_liberacao) where origem = 'pedido' and status = 'a_receber';

-- ---------- trigger do PDV: parcelas ----------
create or replace function sync_lancamento_pedido()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recebido numeric; v_alvo numeric; v_abertas numeric; v_n int; v_i int; v_acum numeric; v_val numeric; v_tax numeric;
  r record;
begin
  if new.ml_order_id is not null then
    return new;                      -- venda do ML: quem cuida é a Edge Function
  end if;

  if tg_op = 'INSERT' then
    -- padrão: à vista, 1 parcela já recebida (a venda com condição é refeita
    -- logo em seguida por criar_pedido_venda_parcelado, na mesma transação)
    insert into lancamentos_financeiros
      (origem, canal, categoria, pedido_id, data_competencia, data_liberacao, status, recebido_em,
       parcela_num, parcela_total, valor_bruto, taxas, valor_liquido, forma_pagamento, sincronizado_em)
    values
      ('pedido', new.canal::text, 'venda', new.id, new.data_pedido, new.data_pedido,
       case when new.status = 'cancelado' then 'estornado' else 'recebido' end,
       case when new.status = 'cancelado' then null else new.data_pedido end,
       1, 1, new.valor_total, new.taxas_canal, new.valor_total - coalesce(new.taxas_canal, 0),
       new.forma_pagamento, now())
    on conflict do nothing;
    return new;
  end if;

  -- canal / data da venda
  if new.canal is distinct from old.canal or new.data_pedido is distinct from old.data_pedido then
    update lancamentos_financeiros
       set canal = new.canal::text, data_competencia = new.data_pedido, updated_at = now()
     where pedido_id = new.id and origem = 'pedido';
    -- à vista de 1 parcela (data não ajustada à mão) acompanha a data da venda
    update lancamentos_financeiros
       set data_liberacao = new.data_pedido,
           recebido_em = case when recebido_em is not null then new.data_pedido end
     where pedido_id = new.id and origem = 'pedido' and parcela_total = 1
       and not liberacao_editada and data_liberacao = old.data_pedido;
  end if;

  -- valor / taxas
  if new.valor_total is distinct from old.valor_total or new.taxas_canal is distinct from old.taxas_canal then
    select count(*) into v_n from lancamentos_financeiros where pedido_id = new.id and origem = 'pedido';
    if v_n = 1 then
      -- 1 parcela só: acompanha o valor do pedido (como antes do Lote 7)
      update lancamentos_financeiros
         set valor_bruto = new.valor_total, taxas = new.taxas_canal,
             valor_liquido = new.valor_total - coalesce(new.taxas_canal, 0), updated_at = now()
       where pedido_id = new.id and origem = 'pedido';
    else
      -- várias parcelas: recebidas ficam como estão; abertas dividem o que falta
      select coalesce(sum(valor_bruto), 0) into v_recebido from lancamentos_financeiros
       where pedido_id = new.id and origem = 'pedido' and status = 'recebido';
      select coalesce(sum(valor_bruto), 0), count(*) into v_abertas, v_n from lancamentos_financeiros
       where pedido_id = new.id and origem = 'pedido' and status = 'a_receber';
      v_alvo := new.valor_total - v_recebido;
      if v_n > 0 and v_alvo > 0 then
        v_i := 0; v_acum := 0;
        for r in select id, valor_bruto from lancamentos_financeiros
                  where pedido_id = new.id and origem = 'pedido' and status = 'a_receber' order by parcela_num loop
          v_i := v_i + 1;
          v_val := case when v_i = v_n then v_alvo - v_acum
                        when v_abertas > 0 then round(v_alvo * r.valor_bruto / v_abertas, 2)
                        else round(v_alvo / v_n, 2) end;
          v_acum := v_acum + v_val;
          v_tax := case when new.valor_total > 0 then round(coalesce(new.taxas_canal, 0) * v_val / new.valor_total, 2) else 0 end;
          update lancamentos_financeiros set valor_bruto = v_val, taxas = v_tax, valor_liquido = v_val - v_tax, updated_at = now()
           where id = r.id;
        end loop;
      else
        update lancamentos_financeiros
           set observacao = concat_ws(' | ', nullif(observacao, ''),
                 '⚠ Valor do pedido mudou para R$ ' || new.valor_total || ' e não há parcela em aberto pra ajustar — conferir')
         where pedido_id = new.id and origem = 'pedido'
           and parcela_num = (select max(parcela_num) from lancamentos_financeiros where pedido_id = new.id and origem = 'pedido');
      end if;
    end if;
  end if;

  -- cancelamento / reativação
  if new.status = 'cancelado' and old.status is distinct from 'cancelado' then
    update lancamentos_financeiros set status = 'estornado', updated_at = now()
     where pedido_id = new.id and origem = 'pedido' and recebido_em is null and status <> 'estornado';
    update lancamentos_financeiros
       set observacao = concat_ws(' | ', nullif(observacao, ''), '⚠ Pedido cancelado — esta parcela já tinha sido recebida: verificar devolução'),
           updated_at = now()
     where pedido_id = new.id and origem = 'pedido' and recebido_em is not null;
  elsif new.status = 'confirmado' and old.status = 'cancelado' then
    update lancamentos_financeiros
       set status = case when recebido_em is not null then 'recebido' else 'a_receber' end, updated_at = now()
     where pedido_id = new.id and origem = 'pedido' and status = 'estornado';
  end if;
  return new;
end;
$$;

-- ---------- criar venda já com as parcelas (tudo numa transação só) ----------
-- p_parcelas: [{"valor": 300.00, "vencimento": "2026-10-06"}, {"valor": 700.00, "vencimento": "2026-11-05"}]
create or replace function criar_pedido_venda_parcelado(
  p_canal canal_venda, p_cliente_nome text, p_local_baixa_estoque local_estoque,
  p_data_pedido timestamptz, p_valor_frete numeric, p_desconto numeric, p_taxas_canal numeric,
  p_observacao text, p_itens jsonb,
  p_parcelas jsonb, p_forma_pagamento text default null, p_condicao text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid; v_total numeric; v_taxas numeric; v_dia_venda date; v_soma numeric; v_n int; v_i int := 0;
  v_tax_acum numeric := 0; v_tax numeric; v_venc date; v_val numeric; e jsonb;
begin
  if p_parcelas is null or jsonb_typeof(p_parcelas) <> 'array' or jsonb_array_length(p_parcelas) = 0 then
    raise exception 'Informe as parcelas.';
  end if;
  v_id := criar_pedido_venda(p_canal, p_cliente_nome, p_local_baixa_estoque, p_data_pedido, p_valor_frete,
                             p_desconto, p_taxas_canal, p_observacao, p_itens);
  select valor_total, coalesce(taxas_canal, 0), (data_pedido at time zone 'America/Sao_Paulo')::date
    into v_total, v_taxas, v_dia_venda from pedidos_venda where id = v_id;

  select sum((x->>'valor')::numeric), count(*) into v_soma, v_n from jsonb_array_elements(p_parcelas) x;
  if exists (select 1 from jsonb_array_elements(p_parcelas) x
             where (x->>'valor') is null or (x->>'valor')::numeric <= 0 or (x->>'vencimento') is null) then
    raise exception 'Toda parcela precisa de valor maior que zero e data de vencimento.';
  end if;
  if abs(v_soma - v_total) > 0.005 then
    raise exception 'A soma das parcelas (R$ %) é diferente do total do pedido (R$ %).', v_soma, v_total;
  end if;

  delete from lancamentos_financeiros where pedido_id = v_id and origem = 'pedido';
  for e in select x from jsonb_array_elements(p_parcelas) x order by (x->>'vencimento')::date loop
    v_i := v_i + 1;
    v_val := (e->>'valor')::numeric;
    v_venc := (e->>'vencimento')::date;
    v_tax := case when v_i = v_n then v_taxas - v_tax_acum
                  when v_total > 0 then round(v_taxas * v_val / v_total, 2) else 0 end;
    v_tax_acum := v_tax_acum + v_tax;
    insert into lancamentos_financeiros
      (origem, canal, categoria, pedido_id, data_competencia, data_liberacao, status, recebido_em,
       parcela_num, parcela_total, valor_bruto, taxas, valor_liquido, forma_pagamento, sincronizado_em)
    select 'pedido', pv.canal::text, 'venda', pv.id, pv.data_pedido,
           -- vencimento ao meio-dia de Brasília (não "vira" de dia por fuso)
           (v_venc + time '12:00') at time zone 'America/Sao_Paulo',
           case when v_venc <= v_dia_venda then 'recebido' else 'a_receber' end,
           case when v_venc <= v_dia_venda then pv.data_pedido end,
           v_i, v_n, v_val, v_tax, v_val - v_tax, nullif(btrim(p_forma_pagamento), ''), now()
      from pedidos_venda pv where pv.id = v_id;
  end loop;

  update pedidos_venda
     set condicao_pagamento = nullif(btrim(p_condicao), ''), forma_pagamento = nullif(btrim(p_forma_pagamento), '')
   where id = v_id;
  return v_id;
end;
$$;

-- ---------- baixa / desfazer baixa ----------
create or replace function baixar_parcelas(p_ids uuid[], p_data date default null, p_forma text default null)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare v_n integer;
begin
  update lancamentos_financeiros
     set status = 'recebido',
         recebido_em = (coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date) + time '12:00') at time zone 'America/Sao_Paulo',
         forma_pagamento = coalesce(nullif(btrim(p_forma), ''), forma_pagamento),
         updated_at = now()
   where id = any(p_ids) and origem = 'pedido' and status = 'a_receber';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function desfazer_baixa_parcela(p_id uuid)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare v_n integer;
begin
  update lancamentos_financeiros
     set status = 'a_receber', recebido_em = null, updated_at = now()
   where id = p_id and origem = 'pedido' and status = 'recebido';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function criar_pedido_venda_parcelado(canal_venda, text, local_estoque, timestamptz, numeric, numeric, numeric, text, jsonb, jsonb, text, text) from public, anon;
revoke all on function baixar_parcelas(uuid[], date, text) from public, anon;
revoke all on function desfazer_baixa_parcela(uuid) from public, anon;
grant execute on function criar_pedido_venda_parcelado(canal_venda, text, local_estoque, timestamptz, numeric, numeric, numeric, text, jsonb, jsonb, text, text) to authenticated;
grant execute on function baixar_parcelas(uuid[], date, text) to authenticated;
grant execute on function desfazer_baixa_parcela(uuid) to authenticated;

-- ---------- funções de consulta (mesmas do 4c/4d + parcela, vencida, forma) ----------
drop function if exists contas_receber_listar(date, date, text[], text[], text, text, integer, integer, date[]);
drop function if exists contas_receber_resumo(date, date, text[], text[], text, text, date[]);
drop function if exists contas_receber_mensal(date, date, date[], text[], text[], text, text);
drop function if exists contas_receber_base(date, date, text[], text[], text, text, text, date[]);

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
  custo numeric, custo_status text, nomes_sem_custo text, lucro numeric, observacao text,
  vencido boolean, parcela_num integer, parcela_total integer, recebido_em timestamptz,
  forma_pagamento text, condicao_pagamento text
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
             -- Lote 7: parcela de pedido do PDV só vira "recebido" com a baixa (botão "Recebi")
             when l.origem = 'pedido' then l.status
             when l.data_liberacao <= now() then 'recebido'
             else 'a_receber'
           end as status_ef,
           -- Lote 7: parcela do PDV vencida e ainda não recebida
           (l.origem = 'pedido' and l.status = 'a_receber'
            and (l.data_liberacao at time zone 'America/Sao_Paulo')::date
                < (now() at time zone 'America/Sao_Paulo')::date) as vencido,
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
      and (p_status is null or cardinality(p_status) = 0 or status_ef = any(p_status)
           or ('vencido' = any(p_status) and vencido))   -- Lote 7: filtro "vencidas"
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
           pv.cliente_nome_avulso, pv.numero_pedido, pv.condicao_pagamento as condicao_pv,
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
         c.observacao,
         c.vencido, c.parcela_num, c.parcela_total, c.recebido_em,
         c.forma_pagamento, c.condicao_pv
  from c
  where p_texto is null or btrim(p_texto) = '' or
        concat_ws(' ', c.descricao, c.produtos, c.skus, c.cliente_nome_avulso, c.ml_order_id,
                  c.numero_pedido, c.observacao, c.canal) ilike
        '%' || replace(replace(replace(btrim(p_texto), '\', '\\'), '%', '\%'), '_', '\_') || '%'
$$;

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
    'liquido_sem_custo',coalesce(sum(valor_liquido) filter (where custo_status = 'sem_custo'), 0),
    'qtd_vencido',      count(*) filter (where vencido),
    'valor_vencido',    coalesce(sum(valor_liquido) filter (where vencido), 0)
  )
  from contas_receber_base(p_inicio, p_fim, p_canais, p_status, p_texto, p_campo_data, 'receber', p_meses)
$$;

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

-- ---------- conferência 1: contas a receber IGUAL antes/depois ----------
do $$
declare a record; r jsonb; r2 jsonb; m jsonb; k text;
begin
  select * into a from _antes;
  r  := contas_receber_resumo(null, null, null, null, null, 'liberacao', null);
  r2 := contas_receber_resumo(null, null, null, array['a_receber','recebido'], null, 'liberacao', null);
  select jsonb_agg(jsonb_build_object('m', mes, 'c', canal, 'l', liquido, 'u', lucro, 'q', qtd) order by mes, canal)
    into m from contas_receber_mensal(null, null, null, null, array['a_receber','recebido'], null, 'receber');
  for k in select jsonb_object_keys(a.resumo) loop
    if (a.resumo->k) is distinct from (r->k) or (a.resumo2->k) is distinct from (r2->k) then
      raise exception 'PARADO: o resumo do contas a receber mudou em "%" (% → %). Nada foi aplicado.', k, a.resumo->k, r->k;
    end if;
  end loop;
  if m is distinct from a.mensal then
    raise exception 'PARADO: o gráfico mensal mudou. Nada foi aplicado.';
  end if;
end $$;

-- ---------- teste completo (tudo desfeito no fim) ----------
do $$
declare
  v_prod uuid; v_id uuid; v_id2 uuid; n int; s numeric; p1 record; p2 record; r jsonb; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  select id into v_prod from produtos where ativo and tipo = 'produto_acabado' order by nome limit 1;
  begin
    -- venda de R$ 1.000 em 30% hoje + 70% em 30 dias
    v_id := criar_pedido_venda_parcelado('loja_fisica', 'TESTE LOTE 7', 'fisico', now(), 0, 0, 0, 'teste',
              jsonb_build_array(jsonb_build_object('produto_id', v_prod, 'quantidade', 1, 'preco_unitario', 1000)),
              jsonb_build_array(jsonb_build_object('valor', 300, 'vencimento', v_hoje),
                                jsonb_build_object('valor', 700, 'vencimento', v_hoje + 30)),
              'Pix', 'Entrada 30% + 30 dias');
    select count(*), sum(valor_bruto) into n, s from lancamentos_financeiros where pedido_id = v_id;
    if n <> 2 or s <> 1000 then raise exception 'PARADO: parcelas erradas (% / %).', n, s; end if;
    select * into p1 from lancamentos_financeiros where pedido_id = v_id and parcela_num = 1;
    select * into p2 from lancamentos_financeiros where pedido_id = v_id and parcela_num = 2;
    if p1.status <> 'recebido' or p1.valor_liquido <> 300 or p2.status <> 'a_receber' or p2.valor_liquido <> 700
       or p2.parcela_total <> 2 or p1.forma_pagamento <> 'Pix'
       or (p2.data_liberacao at time zone 'America/Sao_Paulo')::date <> v_hoje + 30 then
      raise exception 'PARADO: status/valores/data das parcelas errados.';
    end if;
    if (select condicao_pagamento from pedidos_venda where id = v_id) <> 'Entrada 30% + 30 dias' then
      raise exception 'PARADO: condição não gravada no pedido.';
    end if;
    -- soma errada tem que ser recusada
    begin
      perform criar_pedido_venda_parcelado('loja_fisica', 'TESTE', 'fisico', now(), 0, 0, 0, null,
              jsonb_build_array(jsonb_build_object('produto_id', v_prod, 'quantidade', 1, 'preco_unitario', 100)),
              jsonb_build_array(jsonb_build_object('valor', 90, 'vencimento', v_hoje)), null, null);
      raise exception 'PARADO: aceitou parcelas com soma errada.';
    exception when raise_exception then
      if sqlerrm like 'PARADO%' then raise; end if;
    end;
    -- vencida: joga a parcela 2 pra ontem
    update lancamentos_financeiros set data_liberacao = now() - interval '1 day' where id = p2.id;
    select count(*) into n from contas_receber_base(null, null, null, array['vencido'], 'TESTE LOTE 7', 'liberacao', 'receber', null) where vencido;
    if n <> 1 then raise exception 'PARADO: vencida não apareceu (%).', n; end if;
    r := contas_receber_resumo(null, null, null, null, 'TESTE LOTE 7', 'liberacao', null);
    if (r->>'qtd_vencido')::int <> 1 or (r->>'valor_vencido')::numeric <> 700 then raise exception 'PARADO: resumo de vencidas errado (%).', r; end if;
    -- baixa
    if baixar_parcelas(array[p2.id], v_hoje, 'Dinheiro') <> 1 then raise exception 'PARADO: baixa não aconteceu.'; end if;
    select * into p2 from lancamentos_financeiros where id = p2.id;
    if p2.status <> 'recebido' or p2.recebido_em is null or p2.forma_pagamento <> 'Dinheiro' then raise exception 'PARADO: baixa gravou errado.'; end if;
    if baixar_parcelas(array[p2.id], null, null) <> 0 then raise exception 'PARADO: baixou duas vezes.'; end if;
    -- desfazer baixa
    if desfazer_baixa_parcela(p2.id) <> 1 then raise exception 'PARADO: desfazer baixa falhou.'; end if;
    -- mudança de valor: recebida (300) fica, aberta vira 900
    update pedidos_venda set valor_total = 1200 where id = v_id;
    select * into p1 from lancamentos_financeiros where pedido_id = v_id and parcela_num = 1;
    select * into p2 from lancamentos_financeiros where pedido_id = v_id and parcela_num = 2;
    if p1.valor_bruto <> 300 or p2.valor_bruto <> 900 then raise exception 'PARADO: recálculo errado (% / %).', p1.valor_bruto, p2.valor_bruto; end if;
    -- cancelamento: aberta estornada, recebida com aviso
    update pedidos_venda set status = 'cancelado' where id = v_id;
    select * into p1 from lancamentos_financeiros where pedido_id = v_id and parcela_num = 1;
    select * into p2 from lancamentos_financeiros where pedido_id = v_id and parcela_num = 2;
    if p2.status <> 'estornado' or p1.status <> 'recebido' or p1.observacao not like '%devolução%' then
      raise exception 'PARADO: cancelamento tratado errado.';
    end if;
    -- venda à vista pelo caminho antigo (criar_pedido_venda direto): 1 parcela recebida
    v_id2 := criar_pedido_venda('loja_fisica', 'TESTE LOTE 7B', 'fisico', now(), 0, 0, 0, null,
              jsonb_build_array(jsonb_build_object('produto_id', v_prod, 'quantidade', 1, 'preco_unitario', 50)));
    select count(*) into n from lancamentos_financeiros where pedido_id = v_id2 and status = 'recebido' and valor_bruto = 50 and parcela_total = 1;
    if n <> 1 then raise exception 'PARADO: venda à vista simples não gerou 1 parcela recebida.'; end if;
    raise exception 'TESTE_OK';
  exception when raise_exception then
    if sqlerrm <> 'TESTE_OK' then raise; end if;
  end;
end $$;

-- ---------- conferência 2: faturamento e estoque iguais ----------
do $$
declare a record;
begin
  select * into a from _antes;
  if a.fat <> (select coalesce(sum(valor_total) filter (where status = 'confirmado'), 0) from pedidos_venda)
     or a.n_ped <> (select count(*) from pedidos_venda)
     or a.estoque <> (select coalesce(sum(quantidade), 0) from estoque_saldos)
     or a.n_lanc <> (select count(*) from lancamentos_financeiros) then
    raise exception 'PARADO: faturamento/estoque/lançamentos mudaram. Nada foi aplicado.';
  end if;
end $$;

commit;

select 'ok — condição de pagamento pronta; contas a receber igual; teste passou' as status,
       (select count(*) from condicoes_pagamento) as condicoes,
       (select count(*) from lancamentos_financeiros where origem = 'pedido') as parcelas_pdv,
       (select count(*) filter (where status = 'recebido') from lancamentos_financeiros where origem = 'pedido') as pdv_recebidas;
