// ============================================================
// ERP E-Factory — Edge Function: ml-sync-receber   (Lote 4, 2026-10-06)
// CONTAS A RECEBER do Mercado Livre.
//
// Pra cada venda do ML (fila = vendas novas + vendas cujo dinheiro ainda
// não foi liberado / liberado há pouco), lê o pedido no ML e cada pagamento
// no Mercado Pago e grava UMA LINHA POR PAGAMENTO em lancamentos_financeiros:
// bruto, tarifa ML, frete pago pelo vendedor, taxas MP, líquido, data e status
// de liberação (exatamente a data que o ML informa — não calcula prazo).
//
// Também:
//  • atualiza as colunas de líquido do Lote 3 em pedidos_venda com a MESMA
//    conta (corrige o frete quando o comprador pagou parte dele);
//  • venda CANCELADA no ML que ainda está "confirmado" no ERP → registra o
//    cancelamento (sai do faturamento). Estoque só volta se: estoque físico,
//    o envio nunca saiu e o cancelamento é recente (≤ 3 dias). Full nunca
//    (a sincronização do Full já corrige o saldo real).
//
// NUNCA mexe em valor_total (faturamento bruto) nem em itens/estoque fora
// da regra de cancelamento acima.
//
// Parâmetros (URL):
//   ?limite=40        vendas por chamada (máx 80)
//   ?desde=AAAA-MM-DD só vendas a partir dessa data
//   ?pedido=<uuid>    só esse pedido do ERP
// Chamada pelo pg_cron (a cada 15 min), ao abrir a aba e pelo botão.
// "Verify JWT" DESLIGADO (igual às outras).
// ============================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

const ESPERAS_RETRY_SUPABASE_MS = [300, 1000, 2500, 5000, 10000];
async function fetchComRetrySupabase(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  for (let tentativa = 0; ; tentativa++) {
    const resp = await fetch(input, init);
    if (resp.status !== 401 || tentativa >= ESPERAS_RETRY_SUPABASE_MS.length) return resp;
    const corpo = await resp.clone().text();
    if (!corpo.includes('PGRST303') && !/issued at future/i.test(corpo)) return resp;
    await new Promise((r) => setTimeout(r, ESPERAS_RETRY_SUPABASE_MS[tentativa]));
  }
}

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { global: { fetch: fetchComRetrySupabase } }
);

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

class LimiteML extends Error {}

async function getAccessToken(canal: string, forcarRenovacao = false): Promise<string | null> {
  const { data: integ, error } = await supabase.from('integracoes_ml').select('*').eq('canal', canal).maybeSingle();
  if (error || !integ) return null;
  if (!forcarRenovacao && Date.now() < new Date(integ.expires_at).getTime() - 60000) return integ.access_token;
  const resp = await fetch('https://api.mercadolibre.com/oauth/token', {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: Deno.env.get('ML_CLIENT_ID')!,
      client_secret: Deno.env.get('ML_CLIENT_SECRET')!,
      refresh_token: integ.refresh_token,
    }),
  });
  const data = await resp.json();
  if (!resp.ok) { console.error('Erro ao renovar token ML:', data); return null; }
  await supabase.from('integracoes_ml').update({
    access_token: data.access_token, refresh_token: data.refresh_token,
    expires_at: new Date(Date.now() + data.expires_in * 1000).toISOString(), updated_at: new Date().toISOString(),
  }).eq('canal', canal);
  return data.access_token;
}

const r2 = (n: number) => (Math.round(n * 100) / 100) || 0;   // || 0 evita "-0"

// ------------------------------------------------------------
// UM pagamento do Mercado Pago → valores separados.
// (Mesma função colada no ml-webhook e no ml-sync-liquido.)
//   bruto  = transaction_amount (preço dos produtos — igual ao faturamento)
//   tarifa = cobranças "ml_*" pagas pelo vendedor
//   frete  = frete cobrado do vendedor − parte que o comprador pagou (shipping_amount)
//   taxas  = demais taxas do vendedor − créditos recebidos do comprador (ex: financing_transfer)
//   líquido= net_received_amount (− reembolso parcial, + taxas devolvidas)
//   ajuste = bruto − tarifa − frete − taxas − líquido (normalmente 0,00)
// Validado em 06/10/2026: 59,75−6,81−9,75−0,06=43,13; 36,95−4,21−(17,14−9,99)−0,04=25,55;
// 21,45−1,88−(16,94−9,99)−(3,90+0,59−3,90)=12,03.
// ------------------------------------------------------------
function analisarPagamento(mp: any) {
  const st = String(mp.status || '');
  let tarifa = 0, freteCobrado = 0, taxas = 0, creditos = 0, taxasDevolvidas = 0;
  const charges: any[] = [];
  for (const c of mp.charges_details || []) {
    const orig = Number(c.amounts?.original || 0);
    const dev = Number(c.amounts?.refunded || 0);
    const v = orig - dev;
    const de = c.accounts?.from, para = c.accounts?.to;
    charges.push([c.name, c.type, de, para, orig, dev]);
    if (de === 'collector') {
      taxasDevolvidas += dev;
      if (c.type === 'shipping') freteCobrado += v;
      else if (String(c.name || '').startsWith('ml_')) tarifa += v;
      else taxas += v;
    } else if (para === 'collector') {
      creditos += v;
    }
  }
  const bruto = Number(mp.transaction_amount || 0);
  const reembolsado = Number(mp.transaction_amount_refunded || 0);
  const net = Number(mp.transaction_details?.net_received_amount ?? 0);
  const frete = freteCobrado - Number(mp.shipping_amount || 0);
  const taxasLiq = taxas - creditos;

  // tipo: valido (aprovado/em disputa), aguardando, estornado, ignorar (nunca foi pago)
  let tipo: 'valido' | 'aguardando' | 'estornado' | 'ignorar';
  if (['approved', 'in_mediation'].includes(st)) tipo = 'valido';
  else if (['refunded', 'charged_back'].includes(st)) tipo = 'estornado';
  else if (['pending', 'in_process', 'authorized'].includes(st)) tipo = 'aguardando';
  else tipo = 'ignorar';                                  // rejected, cancelled (nunca entrou dinheiro)

  let liquido = 0;
  if (tipo === 'valido') liquido = net - reembolsado + (reembolsado > 0 ? taxasDevolvidas : 0);
  const parcial = tipo === 'valido' && reembolsado > 0;

  const valores = tipo === 'valido'
    ? { tarifa: r2(tarifa), frete: r2(frete), taxas: r2(taxasLiq), liquido: r2(liquido),
        ajuste: r2(bruto - tarifa - frete - taxasLiq - liquido) }
    : { tarifa: 0, frete: 0, taxas: 0, liquido: 0, ajuste: 0 };

  return {
    tipo, parcial,
    bruto: r2(bruto),
    reembolsado: r2(reembolsado),
    ...valores,
    data_liberacao: mp.money_release_date || null,
    release_status: mp.money_release_status || null,
    status_mp: st,
    parcelas: mp.installments ?? null,
    resumo: {
      status: st, status_detail: mp.status_detail, date_approved: mp.date_approved,
      money_release_date: mp.money_release_date, money_release_status: mp.money_release_status,
      money_release_schema: mp.money_release_schema ?? null,
      transaction_amount: mp.transaction_amount, shipping_amount: mp.shipping_amount,
      net_received_amount: net, transaction_amount_refunded: reembolsado, charges,
    },
  };
}

// Colunas de líquido do Lote 3 (pedidos_venda) a partir dos pagamentos lidos.
// (Mesma função colada no ml-webhook e no ml-sync-liquido.)
function agregarLote3(lidos: any[]) {
  if (!lidos.length) return { valor_liquido: null, liquido_status: 'sem_pagamento' };
  const validos = lidos.filter((a) => a.tipo === 'valido');
  const soma = (k: string) => r2(validos.reduce((s, a) => s + Number(a[k] || 0), 0));
  if (validos.length) return {
    valor_liquido: soma('liquido'), liquido_tarifa_ml: soma('tarifa'), liquido_frete_vendedor: soma('frete'),
    liquido_taxas_mp: r2(soma('taxas') + soma('ajuste')),            // inclui o ajuste: bruto − tarifa − frete − taxas = líquido
    liquido_status: validos.some((a) => a.parcial) ? 'reembolso_parcial' : 'ok',
  };
  if (lidos.some((a) => a.tipo === 'aguardando')) return { valor_liquido: null, liquido_status: 'pendente' };
  return { valor_liquido: 0, liquido_tarifa_ml: 0, liquido_frete_vendedor: 0, liquido_taxas_mp: 0, liquido_status: 'estornado' };
}

async function mlGet(url: string, canal: string, tokens: Record<string, string | null>) {
  let token = tokens[canal];
  if (!token) return { status: 0, json: null };
  let r = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (r.status === 401) {
    tokens[canal] = token = await getAccessToken(canal, true);
    if (!token) return { status: 401, json: null };
    r = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  }
  if (r.status === 429) throw new LimiteML('limite de requisições do Mercado Livre/Mercado Pago');
  let json: any = null;
  try { json = await r.json(); } catch { /* sem corpo */ }
  return { status: r.status, json };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  const resposta = (obj: any, status = 200) => new Response(JSON.stringify(obj, null, 2), {
    status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json; charset=utf-8' },
  });

  const url = new URL(req.url);
  const limite = Math.min(Math.max(Number(url.searchParams.get('limite')) || 40, 1), 80);
  const desdeParam = url.searchParams.get('desde');
  const desde = desdeParam && /^\d{4}-\d{2}-\d{2}$/.test(desdeParam) ? new Date(desdeParam + 'T00:00:00-03:00').toISOString() : null;
  const pedidoParam = url.searchParams.get('pedido');

  let fila: any[] = [];
  if (pedidoParam && /^[0-9a-f-]{36}$/i.test(pedidoParam)) {
    const { data } = await supabase.from('pedidos_venda')
      .select('id, canal, ml_order_id, status, local_baixa_estoque').eq('id', pedidoParam).not('ml_order_id', 'is', null);
    fila = (data || []).map((p: any) => ({ ...p, local_baixa: p.local_baixa_estoque, novo: false }));
  } else {
    const { data, error } = await supabase.rpc('receber_fila_sync', { p_limite: limite, p_desde: desde });
    if (error) return resposta({ erro: error.message }, 500);
    fila = data || [];
  }

  const tokens: Record<string, string | null> = {};
  const resumo = {
    processados: 0, lancamentos_gravados: 0, cancelados_sem_devolucao: 0, cancelados_com_devolucao: 0,
    devolvidos_sem_cancelamento: 0, com_ajuste: 0, erros: 0, limite_ml: false, detalhes_erro: [] as string[],
  };
  const erro = (msg: string) => { resumo.erros++; if (resumo.detalhes_erro.length < 20) resumo.detalhes_erro.push(msg); };

  async function processar(p: any) {
    if (!(p.canal in tokens)) tokens[p.canal] = await getAccessToken(p.canal);
    if (!tokens[p.canal]) { erro(`${p.ml_order_id}: conta ${p.canal} sem token`); return; }

    const o = await mlGet(`https://api.mercadolibre.com/orders/${p.ml_order_id}`, p.canal, tokens);
    if (o.status !== 200 || !o.json) {
      erro(`${p.ml_order_id}: pedido HTTP ${o.status}`);
      // pedido que não existe mais / sem acesso: marca como lido pra não travar a fila
      if ([403, 404].includes(o.status)) await supabase.from('pedidos_venda').update({ receber_sincronizado_em: new Date().toISOString() }).eq('id', p.id);
      return;
    }
    const order = o.json;

    const linhas: any[] = [];
    const lidos: any[] = [];
    for (const pay of order.payments || []) {
      const mp = await mlGet(`https://api.mercadopago.com/v1/payments/${pay.id}`, p.canal, tokens);
      if (mp.status !== 200 || !mp.json) { erro(`${p.ml_order_id}: pagamento ${pay.id} HTTP ${mp.status}`); return; }
      const a = analisarPagamento(mp.json);
      lidos.push(a);
      if (a.tipo === 'ignorar') continue;

      let status: string;
      if (a.tipo === 'estornado') status = 'estornado';
      else if (a.tipo === 'aguardando') status = 'aguardando';
      else if (a.release_status === 'released' && a.data_liberacao) status = 'recebido';
      else if (a.data_liberacao) status = 'a_receber';
      else status = 'aguardando';
      if (a.ajuste !== 0) resumo.com_ajuste++;

      linhas.push({
        natureza: 'receber', origem: 'ml', canal: p.canal, categoria: 'venda',
        pedido_id: p.id, ml_order_id: String(order.id), ml_payment_id: String(pay.id),
        data_competencia: order.date_created,
        data_liberacao: a.data_liberacao,
        status, ml_payment_status: a.status_mp, ml_release_status: a.release_status, parcelas: a.parcelas,
        valor_bruto: a.bruto, tarifa: a.tarifa, frete: a.frete, taxas: a.taxas, outros_ajustes: a.ajuste,
        valor_reembolsado: a.reembolsado, valor_liquido: a.liquido,
        observacao: a.parcial ? 'Reembolso parcial — líquido = recebido − valor devolvido' : null,
        dados_ml: a.resumo, sincronizado_em: new Date().toISOString(), updated_at: new Date().toISOString(),
      });
    }

    if (linhas.length) {
      const { error: errUp } = await supabase.from('lancamentos_financeiros').upsert(linhas, { onConflict: 'ml_payment_id' });
      if (errUp) { erro(`${p.ml_order_id}: gravar lançamento: ${errUp.message}`); return; }
      resumo.lancamentos_gravados += linhas.length;
    }
    // pagamento que sumiu do pedido ou virou "nunca pago" → apaga a linha antiga
    let apagar = supabase.from('lancamentos_financeiros').delete().eq('pedido_id', p.id).eq('origem', 'ml');
    if (linhas.length) apagar = apagar.not('ml_payment_id', 'in', `(${linhas.map((l) => l.ml_payment_id).join(',')})`);
    const { error: errDel } = await apagar;
    if (errDel) { erro(`${p.ml_order_id}: limpar lançamentos: ${errDel.message}`); return; }

    // colunas de líquido do Lote 3 (mesma conta)
    const validos = lidos.filter((a) => a.tipo === 'valido');
    const estornados = lidos.filter((a) => a.tipo === 'estornado').length;
    const liquidoLote3: any = agregarLote3(lidos);

    // cancelamento no ML → tira do faturamento
    if (order.status === 'cancelled' && p.status === 'confirmado') {
      let devolver = false;
      const ultimaMudanca = new Date(order.last_updated || order.date_last_updated || order.date_closed || 0).getTime();
      const recente = Date.now() - ultimaMudanca < 3 * 86400000;
      if (p.local_baixa === 'fisico' && recente && !desde && order.shipping?.id) {
        const sh = await mlGet(`https://api.mercadolibre.com/shipments/${order.shipping.id}`, p.canal, tokens);
        const saiu = sh.json?.status_history?.date_shipped || ['shipped', 'delivered'].includes(sh.json?.status);
        devolver = sh.status === 200 && !saiu;
      }
      const { error: errCanc } = await supabase.rpc('registrar_cancelamento_ml', { p_pedido_id: p.id, p_devolver_estoque: devolver });
      if (errCanc) erro(`${p.ml_order_id}: cancelar no ERP: ${errCanc.message}`);
      else if (devolver) resumo.cancelados_com_devolucao++;
      else resumo.cancelados_sem_devolucao++;
    } else if (order.status !== 'cancelled' && !validos.length && estornados > 0) {
      resumo.devolvidos_sem_cancelamento++;   // ex: devolução depois de entregue (fica no faturamento)
    }

    await supabase.from('pedidos_venda').update({
      ...liquidoLote3,
      liquido_atualizado_em: new Date().toISOString(),
      receber_sincronizado_em: new Date().toISOString(),
    }).eq('id', p.id);
    resumo.processados++;
  }

  // 4 de cada vez, pra não estourar o limite da API
  try {
    for (let i = 0; i < fila.length; i += 4) {
      await Promise.all(fila.slice(i, i + 4).map((p) => processar(p).catch((e) => {
        if (e instanceof LimiteML) throw e;
        erro(`${p.ml_order_id}: ${String(e?.message || e)}`);
      })));
    }
  } catch (e) {
    if (e instanceof LimiteML) resumo.limite_ml = true;
    else erro(String((e as any)?.message || e));
  }

  const { data: restantes } = await supabase.rpc('receber_fila_contagem');
  return resposta({ ...resumo, restantes });
});
