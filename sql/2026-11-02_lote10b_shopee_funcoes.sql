-- ============================================================
-- ERP E-Factory — LOTE 10b (banco) — funções da integração Shopee
-- Só ADICIONA funções novas. Chamadas apenas pelas Edge Functions
-- (service_role); o site não tem acesso a elas.
--
-- importar_pedido_shopee: cria o pedido + itens + baixa do estoque numa
--   transação só (diferente do ml-webhook, que faz em passos separados).
--   Pedido repetido (mesmo order_sn) não duplica: devolve o existente.
-- registrar_cancelamento_shopee: igual ao registrar_cancelamento_ml.
-- ============================================================
begin;

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

create or replace function registrar_cancelamento_shopee(p_pedido_id uuid, p_devolver_estoque boolean)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status status_pedido;
  v_sn text;
begin
  select status, shopee_order_sn into v_status, v_sn from pedidos_venda where id = p_pedido_id for update;
  if v_status is null then raise exception 'Pedido não encontrado'; end if;
  if v_sn is null then raise exception 'Só pedidos da Shopee'; end if;
  if v_status = 'cancelado' then return 'ja_cancelado'; end if;

  if p_devolver_estoque then
    perform cancelar_pedido_venda(p_pedido_id);
  else
    update pedidos_venda set status = 'cancelado', updated_at = now() where id = p_pedido_id;
  end if;

  update pedidos_venda
     set cancelado_ml_em = now(),
         cancelamento_estoque = case when p_devolver_estoque then 'devolvido' else 'nao_devolvido' end,
         observacao = concat_ws(' | ', nullif(observacao, ''),
                                'Cancelado na Shopee (' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY') || ')' ||
                                case when p_devolver_estoque then ' — estoque devolvido' else ' — estoque não mexido' end)
   where id = p_pedido_id;
  return case when p_devolver_estoque then 'cancelado_com_devolucao' else 'cancelado_sem_devolucao' end;
end $$;

revoke all on function importar_pedido_shopee(jsonb, jsonb, boolean) from public, anon, authenticated;
revoke all on function registrar_cancelamento_shopee(uuid, boolean) from public, anon, authenticated;
grant execute on function importar_pedido_shopee(jsonb, jsonb, boolean) to service_role;
grant execute on function registrar_cancelamento_shopee(uuid, boolean) to service_role;

commit;
