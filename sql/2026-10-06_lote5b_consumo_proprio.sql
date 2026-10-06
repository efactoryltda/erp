-- ============================================================
-- ERP E-Factory — LOTE 5b — CONSUMO PRÓPRIO (parte 2 de 2)
-- Produto usado pela própria empresa (não é venda):
--   • baixa SÓ do estoque físico da empresa: produto acabado → "fisico",
--     matéria-prima → "materia_prima". Nunca Full.
--   • saldo pode ficar negativo (decisão do dono).
--   • NÃO cria pedido: não entra em faturamento, contas a receber nem lucro.
--   • guarda o custo unitário do momento (pra DRE no futuro), quem
--     registrou e a data informada.
--   • "Desfazer" devolve ao mesmo estoque com uma movimentação de estorno
--     (nada é apagado).
-- Confere sozinho no fim: faturamento, contas a receber, saldos e
-- movimentações iguais ao antes, e um teste completo (registrar →
-- conferir saldo → desfazer → conferir) que é desfeito automaticamente.
-- Cole TUDO no Supabase → SQL Editor → RUN ("Run without RLS" se avisar).
-- ============================================================
begin;

do $$
begin
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                 where t.typname = 'tipo_movimento_estoque' and e.enumlabel = 'consumo_proprio') then
    raise exception 'PARADO: rode antes a parte 1 (lote5a). Nada foi aplicado.';
  end if;
  if to_regclass('public.vw_custo_unitario') is null then
    raise exception 'PARADO: vw_custo_unitario não existe. Nada foi aplicado.';
  end if;
end $$;

create temp table _antes on commit drop as
  select (select coalesce(sum(valor_total) filter (where status = 'confirmado'), 0) from pedidos_venda) as fat,
         (select count(*) from pedidos_venda) as n_ped,
         (select count(*) from lancamentos_financeiros) as n_lanc,
         (select coalesce(sum(quantidade), 0) from estoque_saldos) as estoque,
         (select count(*) from estoque_saldos) as n_saldos,
         (select count(*) from movimentacoes_estoque) as n_mov;

-- ---------- colunas novas (só acréscimo, todas opcionais) ----------
alter table movimentacoes_estoque
  add column if not exists custo_unitario  numeric(14,4),  -- custo do produto no momento (consumo próprio)
  add column if not exists usuario_email   text,           -- quem registrou
  add column if not exists data_referencia date;           -- data informada pelo usuário

create index if not exists idx_mov_consumo_proprio
  on movimentacoes_estoque(created_at desc) where tipo_movimento = 'consumo_proprio';
create index if not exists idx_mov_referencia on movimentacoes_estoque(referencia_id) where referencia_id is not null;

-- ---------- registrar ----------
create or replace function registrar_consumo_proprio(
  p_produto_id uuid,
  p_quantidade numeric,
  p_data       date default null,
  p_observacao text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_tipo   text;
  v_nome   text;
  v_local  local_estoque;
  v_custo  numeric;
  v_saldo  numeric;
  v_id     uuid;
begin
  if p_quantidade is null or p_quantidade <= 0 then
    raise exception 'Informe uma quantidade maior que zero.';
  end if;
  select tipo::text, nome into v_tipo, v_nome from produtos where id = p_produto_id;
  if v_tipo is null then raise exception 'Produto não encontrado.'; end if;

  v_local := case when v_tipo = 'materia_prima' then 'materia_prima'::local_estoque else 'fisico'::local_estoque end;
  select custo_unitario into v_custo from vw_custo_unitario where produto_id = p_produto_id;

  insert into estoque_saldos (produto_id, local, quantidade)
  values (p_produto_id, v_local, -p_quantidade)
  on conflict (produto_id, local) do update
    set quantidade = estoque_saldos.quantidade - p_quantidade, updated_at = now()
  returning quantidade into v_saldo;

  insert into movimentacoes_estoque
    (produto_id, local, tipo_movimento, quantidade, referencia_tipo, observacao,
     custo_unitario, usuario_email, data_referencia)
  values
    (p_produto_id, v_local, 'consumo_proprio', -p_quantidade, 'consumo_proprio', nullif(btrim(p_observacao), ''),
     v_custo, auth.jwt() ->> 'email',
     coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date))
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'produto', v_nome, 'local', v_local, 'saldo', v_saldo);
end;
$$;

-- ---------- desfazer (devolve ao mesmo estoque) ----------
create or replace function desfazer_consumo_proprio(p_movimentacao_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  m       movimentacoes_estoque%rowtype;
  v_saldo numeric;
  v_id    uuid;
begin
  select * into m from movimentacoes_estoque where id = p_movimentacao_id for update;
  if m.id is null or m.tipo_movimento <> 'consumo_proprio' or m.referencia_tipo <> 'consumo_proprio' then
    raise exception 'Consumo próprio não encontrado.';
  end if;
  if exists (select 1 from movimentacoes_estoque
             where referencia_id = m.id and referencia_tipo = 'estorno_consumo_proprio') then
    raise exception 'Esse consumo já foi desfeito.';
  end if;

  update estoque_saldos set quantidade = quantidade - m.quantidade, updated_at = now()   -- m.quantidade é negativa
   where produto_id = m.produto_id and local = m.local
  returning quantidade into v_saldo;
  if v_saldo is null then
    insert into estoque_saldos (produto_id, local, quantidade) values (m.produto_id, m.local, -m.quantidade)
    returning quantidade into v_saldo;
  end if;

  insert into movimentacoes_estoque
    (produto_id, local, tipo_movimento, quantidade, referencia_tipo, referencia_id, observacao,
     custo_unitario, usuario_email, data_referencia)
  values
    (m.produto_id, m.local, 'consumo_proprio', -m.quantidade, 'estorno_consumo_proprio', m.id,
     'Desfeito: consumo próprio registrado por engano', m.custo_unitario, auth.jwt() ->> 'email',
     (now() at time zone 'America/Sao_Paulo')::date)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'saldo', v_saldo);
end;
$$;

-- ---------- lista dos últimos consumos ----------
create or replace function listar_consumo_proprio(p_limite integer default 30)
returns table (
  id uuid, produto_id uuid, produto text, sku text, tipo_produto text, local text,
  quantidade numeric, custo_unitario numeric, custo_total numeric,
  data_referencia date, created_at timestamptz, usuario_email text, observacao text,
  desfeito boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  select m.id, m.produto_id, p.nome, p.sku_interno, p.tipo::text, m.local::text,
         -m.quantidade, m.custo_unitario, round(-m.quantidade * m.custo_unitario, 2),
         m.data_referencia, m.created_at, m.usuario_email, m.observacao,
         exists (select 1 from movimentacoes_estoque e
                 where e.referencia_id = m.id and e.referencia_tipo = 'estorno_consumo_proprio')
  from movimentacoes_estoque m
  join produtos p on p.id = m.produto_id
  where m.tipo_movimento = 'consumo_proprio' and m.referencia_tipo = 'consumo_proprio'
  order by m.created_at desc
  limit least(greatest(coalesce(p_limite, 30), 1), 200)
$$;

revoke all on function registrar_consumo_proprio(uuid, numeric, date, text) from public, anon;
revoke all on function desfazer_consumo_proprio(uuid) from public, anon;
revoke all on function listar_consumo_proprio(integer) from public, anon;
grant execute on function registrar_consumo_proprio(uuid, numeric, date, text) to authenticated;
grant execute on function desfazer_consumo_proprio(uuid) to authenticated;
grant execute on function listar_consumo_proprio(integer) to authenticated;

-- ---------- teste completo, desfeito automaticamente ----------
do $$
declare
  v_prod uuid; v_tipo text; v_local local_estoque;
  s0 numeric; s1 numeric; s2 numeric; r jsonb; r2 jsonb; n_lista int;
begin
  select id, tipo::text into v_prod, v_tipo from produtos where ativo order by tipo desc, nome limit 1;   -- 1 acabado
  v_local := case when v_tipo = 'materia_prima' then 'materia_prima'::local_estoque else 'fisico'::local_estoque end;
  begin
    select coalesce((select quantidade from estoque_saldos where produto_id = v_prod and local = v_local), 0) into s0;
    r := registrar_consumo_proprio(v_prod, 2.5, null, 'teste automático');
    select quantidade into s1 from estoque_saldos where produto_id = v_prod and local = v_local;
    if s1 <> s0 - 2.5 or (r->>'local') <> v_local::text then
      raise exception 'PARADO: teste de baixa falhou (% → %).', s0, s1;
    end if;
    select count(*) into n_lista from listar_consumo_proprio(5) l where l.id = (r->>'id')::uuid and not l.desfeito;
    if n_lista <> 1 then raise exception 'PARADO: consumo não apareceu na lista.'; end if;
    r2 := desfazer_consumo_proprio((r->>'id')::uuid);
    select quantidade into s2 from estoque_saldos where produto_id = v_prod and local = v_local;
    if s2 <> s0 then raise exception 'PARADO: desfazer não devolveu o saldo (% → %).', s0, s2; end if;
    begin
      perform desfazer_consumo_proprio((r->>'id')::uuid);
      raise exception 'PARADO: deixou desfazer duas vezes.';
    exception when raise_exception then
      if sqlerrm like 'PARADO%' then raise; end if;   -- esperado: "já foi desfeito"
    end;
    raise exception 'TESTE_OK';            -- desfaz tudo que o teste gravou
  exception when raise_exception then
    if sqlerrm <> 'TESTE_OK' then raise; end if;
  end;
end $$;

-- ---------- conferência: nada mudou além das colunas e funções ----------
do $$
declare a record; d record;
begin
  select * into a from _antes;
  select (select coalesce(sum(valor_total) filter (where status = 'confirmado'), 0) from pedidos_venda) as fat,
         (select count(*) from pedidos_venda) as n_ped,
         (select count(*) from lancamentos_financeiros) as n_lanc,
         (select coalesce(sum(quantidade), 0) from estoque_saldos) as estoque,
         (select count(*) from estoque_saldos) as n_saldos,
         (select count(*) from movimentacoes_estoque) as n_mov
    into d;
  if row(a.fat, a.n_ped, a.n_lanc, a.estoque, a.n_saldos, a.n_mov)
     is distinct from row(d.fat, d.n_ped, d.n_lanc, d.estoque, d.n_saldos, d.n_mov) then
    raise exception 'PARADO: algo mudou (faturamento/estoque/movimentações). Nada foi aplicado.';
  end if;
end $$;

commit;

select 'ok — consumo próprio criado; teste passou; faturamento e estoque intactos' as status,
       (select coalesce(sum(quantidade), 0) from estoque_saldos) as estoque_total,
       (select count(*) from movimentacoes_estoque) as movimentacoes;
