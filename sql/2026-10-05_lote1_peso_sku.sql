-- ============================================================
-- ERP E-Factory — LOTE 1 (banco)
--   [1] Peso do produto com 5 casas decimais
--   [2] Vínculo pedido ML <-> produto (SKU) mais robusto
--       + revínculo de pedidos antigos SEM mexer em estoque
--
-- Cole TUDO no Supabase → SQL Editor → RUN.
-- Roda numa transação única: se qualquer verificação falhar,
-- NADA é aplicado (aparece a mensagem de erro — mande pro Claude).
-- ============================================================
begin;

-- ------------------------------------------------------------
-- VERIFICAÇÃO DE SEGURANÇA
-- As funções de cancelar/excluir pedido serão atualizadas.
-- Antes, confere se elas estão exatamente como no histórico do
-- projeto (pra não sobrescrever alguma alteração feita depois).
-- ------------------------------------------------------------
do $$
declare
  v_cancelar text;
  v_excluir  text;
begin
  select md5(regexp_replace(prosrc, '\s', '', 'g')) into v_cancelar
    from pg_proc where proname = 'cancelar_pedido_venda' and pronamespace = 'public'::regnamespace;
  select md5(regexp_replace(prosrc, '\s', '', 'g')) into v_excluir
    from pg_proc where proname = 'excluir_pedido_venda' and pronamespace = 'public'::regnamespace;

  if v_cancelar is distinct from '8e2715179b6757395be7ea1c43fd549e' then
    raise exception 'PARADO: a função cancelar_pedido_venda está diferente do histórico (%). Nada foi alterado — mande esta mensagem pro Claude.', v_cancelar;
  end if;
  if v_excluir is distinct from '63de2e9612f6ab9ba72350cf42e74be7' then
    raise exception 'PARADO: a função excluir_pedido_venda está diferente do histórico (%). Nada foi alterado — mande esta mensagem pro Claude.', v_excluir;
  end if;
end $$;


-- ============================================================
-- [1] PESO COM 5 CASAS DECIMAIS
-- numeric(12,3) -> numeric(14,5): nenhum valor existente muda.
-- A view vw_oc_itens usa essa coluna, então ela é guardada,
-- removida e recriada exatamente igual (mesma definição,
-- mesmas opções e mesmas permissões).
-- ============================================================
do $$
declare
  v_def   text;
  v_opts  text[];
  v_grant record;
  v_grants text[] := '{}';
begin
  v_def  := pg_get_viewdef('public.vw_oc_itens'::regclass, true);
  select reloptions into v_opts from pg_class where oid = 'public.vw_oc_itens'::regclass;

  for v_grant in
    select grantee, string_agg(privilege_type, ', ') as privs
    from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'vw_oc_itens'
    group by grantee
  loop
    v_grants := v_grants || format('grant %s on public.vw_oc_itens to %I', v_grant.privs, v_grant.grantee);
  end loop;

  -- sem CASCADE de propósito: se outra view depender desta, para tudo aqui
  execute 'drop view public.vw_oc_itens';

  execute 'alter table public.produtos alter column peso_kg type numeric(14,5)';

  execute 'create view public.vw_oc_itens'
       || case when v_opts is not null then ' with (' || array_to_string(v_opts, ', ') || ')' else '' end
       || ' as ' || v_def;

  for i in 1 .. coalesce(array_length(v_grants, 1), 0) loop
    execute v_grants[i];
  end loop;
end $$;


-- ============================================================
-- [2] VÍNCULO PEDIDO ML <-> PRODUTO
-- ============================================================

-- SKUs antigos/alternativos do produto (ex: SKU que o anúncio
-- usava antes de ser renomeado). Preenchido na aba Produtos.
alter table produtos add column if not exists skus_alternativos text[] not null default '{}';

-- ID do anúncio (MLB...) de cada item de pedido do ML
alter table pedido_itens add column if not exists ml_item_id text;

-- Diz se a baixa de estoque desse item realmente aconteceu.
-- Itens que entraram "sem produto" NUNCA baixaram estoque; se
-- forem vinculados depois, continuam sem baixa (evita baixar em
-- dobro — o Full já foi corrigido pela sincronização com o ML).
alter table pedido_itens add column if not exists estoque_baixado boolean not null default true;
update pedido_itens set estoque_baixado = false where produto_id is null;


-- Acha o produto de um item do ML. Ordem:
--   1) SKU do ML do produto   2) SKU interno   3) SKUs alternativos
--   4) ID do anúncio cadastrado no produto
-- Ignora maiúsculas/minúsculas e espaços nas pontas.
-- Se achar MAIS DE UM produto no mesmo passo, não chuta: devolve vazio.
create or replace function encontrar_produto_por_sku(p_sku text, p_item_id text default null)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sku text := upper(btrim(coalesce(p_sku, '')));
  v_item text := upper(btrim(coalesce(p_item_id, '')));
  v_ids uuid[];
begin
  if v_sku <> '' then
    select array_agg(id) into v_ids from produtos where upper(btrim(sku_ml)) = v_sku;
    if array_length(v_ids, 1) = 1 then return v_ids[1]; elsif array_length(v_ids, 1) > 1 then return null; end if;

    select array_agg(id) into v_ids from produtos where upper(btrim(sku_interno)) = v_sku;
    if array_length(v_ids, 1) = 1 then return v_ids[1]; elsif array_length(v_ids, 1) > 1 then return null; end if;

    select array_agg(id) into v_ids from produtos
      where exists (select 1 from unnest(skus_alternativos) a where upper(btrim(a)) = v_sku);
    if array_length(v_ids, 1) = 1 then return v_ids[1]; elsif array_length(v_ids, 1) > 1 then return null; end if;
  end if;

  if v_item <> '' then
    select array_agg(distinct produto_id) into v_ids from produto_anuncios_ml where upper(btrim(item_id)) = v_item;
    if array_length(v_ids, 1) = 1 then return v_ids[1]; end if;
  end if;

  return null;
end;
$$;

grant execute on function encontrar_produto_por_sku(text, text) to authenticated, service_role;


-- Revincula os itens de pedido que estão "sem produto".
-- NÃO mexe em estoque (os itens continuam marcados como sem baixa).
-- Devolve quantos foram vinculados e quantos continuam sem produto.
create or replace function revincular_itens_sem_produto()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vinculados int;
  v_restantes int;
begin
  with achados as (
    select pi.id, encontrar_produto_por_sku(pi.sku_ml_item, pi.ml_item_id) as produto_id
    from pedido_itens pi
    where pi.produto_id is null
  )
  update pedido_itens pi
     set produto_id = a.produto_id
    from achados a
   where pi.id = a.id and a.produto_id is not null;
  get diagnostics v_vinculados = row_count;

  select count(*) into v_restantes from pedido_itens where produto_id is null;

  return jsonb_build_object('vinculados', v_vinculados, 'ainda_sem_produto', v_restantes);
end;
$$;

grant execute on function revincular_itens_sem_produto() to authenticated;


-- Cancelar pedido: agora só devolve estoque dos itens que de fato
-- baixaram estoque (antes, um item sem produto fazia o cancelamento dar erro).
create or replace function cancelar_pedido_venda(p_pedido_id uuid)
returns void
language plpgsql
security definer
as $$
declare
  item record;
  v_local local_estoque;
  v_status status_pedido;
begin
  select status, local_baixa_estoque into v_status, v_local from pedidos_venda where id = p_pedido_id;

  if v_status is null then
    raise exception 'Pedido não encontrado';
  end if;

  if v_status = 'cancelado' then
    raise exception 'Pedido já está cancelado';
  end if;

  for item in
    select produto_id, quantidade from pedido_itens
    where pedido_id = p_pedido_id and produto_id is not null and estoque_baixado
  loop
    insert into estoque_saldos (produto_id, local, quantidade)
    values (item.produto_id, v_local, item.quantidade)
    on conflict (produto_id, local) do update
      set quantidade = estoque_saldos.quantidade + item.quantidade, updated_at = now();

    insert into movimentacoes_estoque (produto_id, local, tipo_movimento, quantidade, referencia_tipo, referencia_id)
    values (item.produto_id, v_local, 'cancelamento_venda', item.quantidade, 'pedido_venda', p_pedido_id);
  end loop;

  update pedidos_venda set status = 'cancelado', updated_at = now() where id = p_pedido_id;
end;
$$;


-- Excluir pedido: mesma regra (só devolve o que foi baixado).
create or replace function excluir_pedido_venda(p_pedido_id uuid)
returns void
language plpgsql
security definer
as $$
declare
  item record;
  v_status status_pedido;
  v_local local_estoque;
begin
  select status, local_baixa_estoque into v_status, v_local from pedidos_venda where id = p_pedido_id;

  if v_status is null then
    raise exception 'Pedido não encontrado';
  end if;

  if v_status = 'confirmado' then
    for item in
      select produto_id, quantidade from pedido_itens
      where pedido_id = p_pedido_id and produto_id is not null and estoque_baixado
    loop
      insert into estoque_saldos (produto_id, local, quantidade)
      values (item.produto_id, v_local, item.quantidade)
      on conflict (produto_id, local) do update
        set quantidade = estoque_saldos.quantidade + item.quantidade, updated_at = now();

      insert into movimentacoes_estoque (produto_id, local, tipo_movimento, quantidade, referencia_tipo, referencia_id)
      values (item.produto_id, v_local, 'cancelamento_venda', item.quantidade, 'pedido_venda_excluido', p_pedido_id);
    end loop;
  end if;

  delete from pedidos_venda where id = p_pedido_id;
end;
$$;


commit;

-- ------------------------------------------------------------
-- CONFERÊNCIA FINAL (roda depois do commit; aparece como resultado do RUN)
-- ------------------------------------------------------------
select
  (select numeric_scale from information_schema.columns
    where table_schema='public' and table_name='produtos' and column_name='peso_kg') as peso_casas_decimais,
  (select count(*) from information_schema.views where table_schema='public' and table_name='vw_oc_itens') as vw_oc_itens_existe,
  (select count(*) from pedido_itens where produto_id is null) as itens_sem_produto,
  (select count(*) from pedido_itens where produto_id is null and encontrar_produto_por_sku(sku_ml_item, ml_item_id) is not null) as itens_que_serao_revinculados;

