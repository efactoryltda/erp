// ============================================================
// ERP E-Factory — Edge Function: ml-webhook
// Recebe o aviso de pedido novo/atualizado do Mercado Livre, busca os
// detalhes completos do pedido, e registra no ERP com baixa de estoque.
// ============================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
);

const FULL_LOCAL_POR_CANAL: Record<string, string> = {
  ml_conta1: 'full_conta1',
  ml_conta2: 'full_conta2',
  ml_conta3: 'full_conta3',
};

async function getAccessToken(canal: string): Promise<string | null> {
  const { data: integ } = await supabase.from('integracoes_ml').select('*').eq('canal', canal).maybeSingle();
  if (!integ) return null;

  const expiraEm = new Date(integ.expires_at).getTime();
  if (Date.now() < expiraEm - 60000) {
    return integ.access_token;
  }

  const clientId = Deno.env.get('ML_CLIENT_ID')!;
  const clientSecret = Deno.env.get('ML_CLIENT_SECRET')!;

  const resp = await fetch('https://api.mercadolibre.com/oauth/token', {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: integ.refresh_token,
    }),
  });
  const data = await resp.json();
  if (!resp.ok) {
    console.error('Erro ao renovar token ML:', data);
    return null;
  }

  const expiresAt = new Date(Date.now() + data.expires_in * 1000).toISOString();
  await supabase
    .from('integracoes_ml')
    .update({ access_token: data.access_token, refresh_token: data.refresh_token, expires_at: expiresAt, updated_at: new Date().toISOString() })
    .eq('canal', canal);

  return data.access_token;
}

async function baixarEstoque(produtoId: string, local: string, quantidade: number, pedidoId: string) {
  const { data: saldo } = await supabase.from('estoque_saldos').select('*').eq('produto_id', produtoId).eq('local', local).maybeSingle();

  if (saldo) {
    await supabase.from('estoque_saldos').update({ quantidade: saldo.quantidade - quantidade, updated_at: new Date().toISOString() }).eq('id', saldo.id);
  } else {
    await supabase.from('estoque_saldos').insert({ produto_id: produtoId, local, quantidade: -quantidade });
  }

  await supabase.from('movimentacoes_estoque').insert({
    produto_id: produtoId,
    local,
    tipo_movimento: 'venda',
    quantidade: -quantidade,
    referencia_tipo: 'pedido_venda',
    referencia_id: pedidoId,
  });
}

Deno.serve(async (req) => {
  try {
    const body = await req.json();
    const { topic, resource, user_id } = body;

    // Só processamos avisos de pedido por enquanto. Outros tópicos (estoque, envio)
    // ficam pra uma próxima fase — respondemos "ok" pra não travar o Mercado Livre.
    if (topic !== 'orders_v2' || !resource || !user_id) {
      return new Response('ok', { status: 200 });
    }

    const { data: integ } = await supabase.from('integracoes_ml').select('canal').eq('ml_user_id', String(user_id)).maybeSingle();
    if (!integ) {
      console.error('Notificação de uma conta ML não conectada:', user_id);
      return new Response('ok', { status: 200 });
    }
    const canal = integ.canal as string;

    const accessToken = await getAccessToken(canal);
    if (!accessToken) {
      console.error('Não consegui obter token de acesso pra', canal);
      return new Response('ok', { status: 200 });
    }

    const orderResp = await fetch(`https://api.mercadolibre.com${resource}`, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    const order = await orderResp.json();
    if (!orderResp.ok) {
      console.error('Erro ao buscar detalhes do pedido:', order);
      return new Response('ok', { status: 200 });
    }

    // evita importar o mesmo pedido duas vezes
    const { data: existente } = await supabase.from('pedidos_venda').select('id').eq('ml_order_id', String(order.id)).maybeSingle();
    if (existente) {
      return new Response('ok', { status: 200 });
    }

    // descobre se o envio é Full (fulfillment) pra baixar do estoque certo
    let localBaixa = 'fisico';
    if (order.shipping?.id) {
      try {
        const shipResp = await fetch(`https://api.mercadolibre.com/shipments/${order.shipping.id}`, {
          headers: { Authorization: `Bearer ${accessToken}` },
        });
        const ship = await shipResp.json();
        if (shipResp.ok && ship.logistic_type === 'fulfillment') {
          localBaixa = FULL_LOCAL_POR_CANAL[canal] || 'fisico';
        }
      } catch (e) {
        console.error('Erro ao checar tipo de envio:', e);
      }
    }

    const itens = (order.order_items || []).map((oi: any) => ({
      sku_ml: String(oi.item?.seller_sku || oi.item?.id || ''),
      quantidade: oi.quantity,
      preco_unitario: oi.unit_price,
    }));

    const valorProdutos = itens.reduce((acc: number, i: any) => acc + i.quantidade * i.preco_unitario, 0);

    const { data: novoPedido, error: errPedido } = await supabase
      .from('pedidos_venda')
      .insert({
        ml_order_id: String(order.id),
        canal,
        cliente_nome_avulso: order.buyer?.nickname || '',
        local_baixa_estoque: localBaixa,
        data_pedido: order.date_created,
        status: 'confirmado',
        valor_produtos: valorProdutos,
        valor_frete: 0,
        desconto: 0,
        taxas_canal: 0,
        valor_total: valorProdutos,
        observacao: 'Importado automaticamente do Mercado Livre',
      })
      .select('id')
      .single();

    if (errPedido || !novoPedido) {
      console.error('Erro ao criar pedido:', errPedido);
      return new Response('ok', { status: 200 });
    }

    for (const item of itens) {
      // tenta achar o produto pelo SKU do Mercado Livre (mesmo produto, independente da conta),
      // depois pelo SKU interno
      let produtoId: string | null = null;
      const { data: porSkuMl } = await supabase.from('produtos').select('id').eq('sku_ml', item.sku_ml).maybeSingle();
      if (porSkuMl) {
        produtoId = porSkuMl.id;
      } else {
        const { data: porSkuInterno } = await supabase.from('produtos').select('id').eq('sku_interno', item.sku_ml).maybeSingle();
        if (porSkuInterno) produtoId = porSkuInterno.id;
      }

      await supabase.from('pedido_itens').insert({
        pedido_id: novoPedido.id,
        produto_id: produtoId,
        sku_ml_item: item.sku_ml,
        quantidade: item.quantidade,
        preco_unitario: item.preco_unitario,
        subtotal: item.quantidade * item.preco_unitario,
      });

      if (produtoId) {
        await baixarEstoque(produtoId, localBaixa, item.quantidade, novoPedido.id);
      } else {
        console.error('Produto não encontrado pro SKU ML:', item.sku_ml, '— item registrado sem baixa de estoque.');
      }
    }

    return new Response('ok', { status: 200 });
  } catch (e) {
    console.error('Erro no webhook do Mercado Livre:', e);
    // sempre responde 200 pro Mercado Livre não ficar re-tentando em loop
    return new Response('ok', { status: 200 });
  }
});
