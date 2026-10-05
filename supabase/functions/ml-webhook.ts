// ============================================================
// ERP E-Factory — Edge Function: ml-webhook
// Recebe o aviso de pedido novo/atualizado do Mercado Livre, busca os
// detalhes completos do pedido, e registra no ERP com baixa de estoque.
// ============================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

// ------------------------------------------------------------
// Proteção contra o erro intermitente do Supabase "JWT issued at future"
// (PGRST303). O JWT é gerado pelo próprio gateway do Supabase a partir da
// chave de serviço; quando o relógio dele fica alguns segundos à frente do
// banco, a consulta é recusada. Não dá pra corrigir o iat do nosso lado —
// então toda chamada ao Supabase passa por aqui e é repetida com espera
// crescente (até ~19s no total) antes de desistir.
// ------------------------------------------------------------
const ESPERAS_RETRY_SUPABASE_MS = [300, 1000, 2500, 5000, 10000];

async function fetchComRetrySupabase(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  for (let tentativa = 0; ; tentativa++) {
    const resp = await fetch(input, init);
    if (resp.status !== 401 || tentativa >= ESPERAS_RETRY_SUPABASE_MS.length) return resp;
    const corpo = await resp.clone().text();
    if (!corpo.includes('PGRST303') && !/issued at future/i.test(corpo)) return resp;
    const espera = ESPERAS_RETRY_SUPABASE_MS[tentativa];
    console.warn(`Supabase recusou com PGRST303 (JWT issued at future) — tentativa ${tentativa + 1}, repetindo em ${espera}ms`);
    await new Promise((r) => setTimeout(r, espera));
  }
}

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { global: { fetch: fetchComRetrySupabase } }
);

const FULL_LOCAL_POR_CANAL: Record<string, string> = {
  ml_conta1: 'full_conta1',
  ml_conta2: 'full_conta2',
  ml_conta3: 'full_conta3',
};

// forcarRenovacao = true: usado quando o Mercado Livre recusou o token (401)
// mesmo dentro da validade — pede um token novo antes de tentar de novo.
async function getAccessToken(canal: string, forcarRenovacao = false): Promise<string | null> {
  const { data: integ, error: errInteg } = await supabase.from('integracoes_ml').select('*').eq('canal', canal).maybeSingle();
  if (errInteg) {
    // erro do banco (não é "conta não conectada") — deixa registrado pra não confundir
    console.error(`Erro ao ler integracoes_ml de ${canal}:`, errInteg.message);
    return null;
  }
  if (!integ) return null;

  const expiraEm = new Date(integ.expires_at).getTime();
  if (!forcarRenovacao && Date.now() < expiraEm - 60000) {
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

const r2 = (n: number) => Math.round(n * 100) / 100;

// ------------------------------------------------------------
// Cálculo do líquido de UM pedido do ML a partir dos pagamentos no
// Mercado Pago. (Mesma função usada no ml-sync-liquido.)
// Devolve null em valor_liquido quando ainda não dá pra saber
// (pagamento pendente) — aí a venda é tentada de novo depois.
// ------------------------------------------------------------
async function calcularLiquido(order: any, token: string) {
  const pagamentos = order.payments || [];
  if (!pagamentos.length) return { valor_liquido: null, liquido_status: 'sem_pagamento' };

  let liquido = 0, tarifa = 0, frete = 0, taxas = 0;
  let aprovados = 0, estornados = 0, pendentes = 0, reembolsoParcial = false;

  for (const p of pagamentos) {
    const resp = await fetch(`https://api.mercadopago.com/v1/payments/${p.id}`, { headers: { Authorization: `Bearer ${token}` } });
    if (resp.status === 401) return { erro401: true } as any;
    if (!resp.ok) return { valor_liquido: null, liquido_status: 'erro', detalhe: `Mercado Pago HTTP ${resp.status}` };
    const mp = await resp.json();

    if (['refunded', 'cancelled', 'charged_back', 'rejected'].includes(mp.status)) { estornados++; continue; }
    if (mp.status !== 'approved') { pendentes++; continue; }

    aprovados++;
    liquido += Number(mp.transaction_details?.net_received_amount ?? 0);
    for (const c of mp.charges_details || []) {
      if (c.accounts?.from !== 'collector') continue;           // só o que é cobrado do vendedor
      const v = Number(c.amounts?.original || 0) - Number(c.amounts?.refunded || 0);
      if (c.type === 'shipping') frete += v;
      else if (String(c.name || '').startsWith('ml_')) tarifa += v;
      else taxas += v;
    }
    if (Number(mp.transaction_amount_refunded || 0) > 0) reembolsoParcial = true;
  }

  if (pendentes > 0 && aprovados === 0) return { valor_liquido: null, liquido_status: 'pendente' };

  return {
    valor_liquido: r2(liquido),
    liquido_tarifa_ml: r2(tarifa),
    liquido_frete_vendedor: r2(frete),
    liquido_taxas_mp: r2(taxas),
    liquido_status: aprovados === 0 && estornados > 0 ? 'estornado' : (reembolsoParcial ? 'reembolso_parcial' : 'ok'),
  };
}

// Calcula e grava SÓ as colunas de líquido do pedido (nunca mexe em
// faturamento, estoque ou status). Qualquer erro aqui só é registrado
// no log — não atrapalha a importação do pedido.
async function gravarLiquido(order: any, canal: string, token: string) {
  try {
    let calc: any = await calcularLiquido(order, token);
    if (calc.erro401) {
      const novo = await getAccessToken(canal, true);
      calc = novo ? await calcularLiquido(order, novo) : { valor_liquido: null, liquido_status: 'erro' };
      if (calc.erro401) calc = { valor_liquido: null, liquido_status: 'erro' };
    }
    if (calc.detalhe) console.error('Líquido do pedido', order.id, calc.detalhe);
    delete calc.detalhe;
    calc.liquido_atualizado_em = new Date().toISOString();
    const { error } = await supabase.from('pedidos_venda').update(calc).eq('ml_order_id', String(order.id));
    if (error) console.error('Erro ao gravar líquido do pedido', order.id, error.message);
  } catch (e) {
    console.error('Erro ao calcular líquido do pedido', order.id, e);
  }
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

    let accessToken = await getAccessToken(canal);
    if (!accessToken) {
      console.error('Não consegui obter token de acesso pra', canal);
      return new Response('ok', { status: 200 });
    }

    let orderResp = await fetch(`https://api.mercadolibre.com${resource}`, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (orderResp.status === 401) {
      // token recusado pelo ML — renova e tenta mais uma vez antes de desistir
      const novoToken = await getAccessToken(canal, true);
      if (novoToken) {
        accessToken = novoToken;
        orderResp = await fetch(`https://api.mercadolibre.com${resource}`, {
          headers: { Authorization: `Bearer ${accessToken}` },
        });
      }
    }
    const order = await orderResp.json();
    if (!orderResp.ok) {
      console.error('Erro ao buscar detalhes do pedido:', order);
      return new Response('ok', { status: 200 });
    }

    // evita importar o mesmo pedido duas vezes. Pedido que já existe: só
    // atualiza o valor líquido (ex: pagamento aprovou depois, estorno) —
    // nada de estoque, status ou faturamento.
    // Pedidos importados ANTES do Lote 3 (liquido_status vazio) não são tocados
    // aqui — esses só recebem líquido pelo backfill, depois da sua aprovação.
    const { data: existente } = await supabase.from('pedidos_venda').select('id, liquido_status').eq('ml_order_id', String(order.id)).maybeSingle();
    if (existente) {
      if (existente.liquido_status) await gravarLiquido(order, canal, accessToken);
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
      ml_item_id: oi.item?.id ? String(oi.item.id) : null,
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
      // Acha o produto no banco (função encontrar_produto_por_sku): tenta SKU do ML,
      // SKU interno, SKUs alternativos e, por último, o ID do anúncio cadastrado no
      // produto — ignorando maiúsculas/minúsculas e espaços. Se der erro, o item entra
      // sem produto (como antes) pra revisão, e pode ser revinculado depois.
      let produtoId: string | null = null;
      const { data: achado, error: errBusca } = await supabase.rpc('encontrar_produto_por_sku', {
        p_sku: item.sku_ml,
        p_item_id: item.ml_item_id,
      });
      if (errBusca) {
        console.error('Erro ao buscar produto pelo SKU', item.sku_ml, errBusca.message);
      } else if (achado) {
        produtoId = achado as string;
      }

      await supabase.from('pedido_itens').insert({
        pedido_id: novoPedido.id,
        produto_id: produtoId,
        sku_ml_item: item.sku_ml,
        ml_item_id: item.ml_item_id,
        // item sem produto não baixa estoque — fica marcado pra não devolver
        // estoque que nunca saiu, se o pedido for cancelado/excluído depois
        estoque_baixado: !!produtoId,
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

    // valor líquido (o que entra de fato) — ao lado do faturamento, sem alterá-lo
    await gravarLiquido(order, canal, accessToken);

    return new Response('ok', { status: 200 });
  } catch (e) {
    console.error('Erro no webhook do Mercado Livre:', e);
    // sempre responde 200 pro Mercado Livre não ficar re-tentando em loop
    return new Response('ok', { status: 200 });
  }
});
