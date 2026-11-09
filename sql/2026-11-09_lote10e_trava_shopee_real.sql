-- ============================================================
-- ERP E-Factory — LOTE 10e — trava da importação da loja Shopee REAL
-- Até o dono aprovar a simulação, pedidos reais não são gravados.
-- Liberar: update integracoes_shopee set importacao_liberada = true;
-- ============================================================
begin;
alter table integracoes_shopee add column if not exists importacao_liberada boolean not null default false;
comment on column integracoes_shopee.importacao_liberada is 'false = pedidos da loja real não são gravados (fase de simulação). Pedidos SANDBOX- não são afetados.';

create or replace function importar_pedido_shopee(p_pedido jsonb, p_itens jsonb, p_baixar_estoque boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_local local_estoque := coalesce(nullif(p_pedido->>'local_baixa_estoque', ''), 'fisico')::local_estoque;
  v_cancelado boolean := (p_pedido->>'status') = 'cancelado';
  v_item jsonb;
  v_produto uuid;
  v_qtd numeric;
  v_preco numeric;
  v_sem_produto int := 0;
  v_total numeric := 0;
begin
  if coalesce(p_pedido->>'shopee_order_sn', '') = '' then
    raise exception 'shopee_order_sn obrigatório';
  end if;

  -- Lote 10e: trava da loja real. Enquanto importacao_liberada = false,
  -- pedido real (sem "SANDBOX-") não é gravado — só depois da simulação.
  if left(p_pedido->>'shopee_order_sn', 8) <> 'SANDBOX-'
     and not coalesce((select importacao_liberada from integracoes_shopee where canal = 'shopee'), false) then
    return jsonb_build_object('id', null, 'novo', false, 'bloqueado', true);
  end if;

  select id into v_id from pedidos_venda where shopee_order_sn = p_pedido->>'shopee_order_sn';
  if v_id is not null then
    return jsonb_build_object('id', v_id, 'novo', false);
  end if;

  select coalesce(sum((i->>'quantidade')::numeric * (i->>'preco_unitario')::numeric), 0)
    into v_total from jsonb_array_elements(p_itens) i;

  insert into pedidos_venda (shopee_order_sn, shopee_status, canal, cliente_nome_avulso, local_baixa_estoque,
                             modalidade_envio, data_pedido, status, valor_produtos, valor_frete, desconto,
                             taxas_canal, valor_total, observacao, cancelado_ml_em, cancelamento_estoque)
  values (p_pedido->>'shopee_order_sn', p_pedido->>'shopee_status', 'shopee', coalesce(p_pedido->>'cliente', ''),
          v_local, nullif(p_pedido->>'modalidade_envio', ''), (p_pedido->>'data_pedido')::timestamptz,
          case when v_cancelado then 'cancelado' else 'confirmado' end::status_pedido,
          v_total, 0, 0, 0, v_total, p_pedido->>'observacao',
          case when v_cancelado then now() end, case when v_cancelado then 'nao_devolvido' end)
  on conflict (shopee_order_sn) do nothing
  returning id into v_id;

  if v_id is null then   -- outra chamada criou ao mesmo tempo
    select id into v_id from pedidos_venda where shopee_order_sn = p_pedido->>'shopee_order_sn';
    return jsonb_build_object('id', v_id, 'novo', false);
  end if;

  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_qtd := (v_item->>'quantidade')::numeric;
    v_preco := (v_item->>'preco_unitario')::numeric;
    v_produto := encontrar_produto_por_sku(v_item->>'sku', null);
    if v_produto is null then v_sem_produto := v_sem_produto + 1; end if;

    insert into pedido_itens (pedido_id, produto_id, quantidade, preco_unitario, subtotal,
                              sku_ml_item, shopee_item_id, shopee_model_id, estoque_baixado)
    values (v_id, v_produto, v_qtd, v_preco, v_qtd * v_preco, v_item->>'sku',
            v_item->>'shopee_item_id', v_item->>'shopee_model_id',
            v_produto is not null and p_baixar_estoque and not v_cancelado);

    if v_produto is not null and p_baixar_estoque and not v_cancelado then
      insert into estoque_saldos (produto_id, local, quantidade)
      values (v_produto, v_local, -v_qtd)
      on conflict (produto_id, local) do update
        set quantidade = estoque_saldos.quantidade - v_qtd, updated_at = now();
      insert into movimentacoes_estoque (produto_id, local, tipo_movimento, quantidade, referencia_tipo, referencia_id)
      values (v_produto, v_local, 'venda', -v_qtd, 'pedido_venda', v_id);
    end if;
  end loop;

  return jsonb_build_object('id', v_id, 'novo', true, 'itens_sem_produto', v_sem_produto);
end $$;

revoke all on function importar_pedido_shopee(jsonb, jsonb, boolean) from public, anon, authenticated;
grant execute on function importar_pedido_shopee(jsonb, jsonb, boolean) to service_role;
commit;
