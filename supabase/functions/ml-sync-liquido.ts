// ============================================================
// ERP E-Factory — Edge Function: ml-sync-liquido
// Preenche o VALOR LÍQUIDO (o que entra de fato, já descontadas
// tarifa do ML, frete pago pelo vendedor e taxas do Mercado Pago)
// das vendas do Mercado Livre que ainda não têm esse valor.
//
// • Só grava as colunas de líquido (valor_liquido, liquido_*).
//   NUNCA mexe em valor_total / faturamento, estoque ou status.
// • Fonte: pagamento no Mercado Pago (transaction_details.net_received_amount)
//   — validado em 05/10/2026 nas 3 contas (ex: 59,75 − 6,81 − 9,75 − 0,06 = 43,13).
//
// Parâmetros (na URL):
//   ?dias=3                  → automático: últimos N dias, só vendas que o webhook já
//                              tentou e ficaram pendentes/erro (padrão 3)
//   ?desde=2026-07-01        → vendas a partir dessa data (backfill — só com aprovação)
//   ?limite=40               → quantas vendas por chamada (máx 80)
//   ?execucao=<ISO>          → início da rodada de backfill: cada venda é tentada
//                              no máximo 1 vez por rodada (evita ficar em loop)
// ============================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

const ESPERAS_RETRY_SUPABASE_MS = [300, 1000, 2500, 5000, 10000];
async function fetchComRetrySupabase(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  for (let tentativa = 0; ; tentativa++) {
    const resp = await fetch(input, init);
    if (resp.status !== 401 || tentativa >= ESPERAS_RETRY_SUPABASE_MS.length) return resp;
    const corpo = await resp.clone().text();
    if (!corpo.includes('PGRST303') && !/issued at future/i.test(corpo)) return resp;
    console.warn(`Supabase recusou com PGRST303 — tentativa ${tentativa + 1}`);
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

async function getAccessToken(canal: string, forcarRenovacao = false): Promise<string | null> {
  const { data: integ, error } = await supabase.from('integracoes_ml').select('*').eq('canal', canal).maybeSingle();
  if (error) { console.error(`Erro ao ler integracoes_ml de ${canal}:`, error.message); return null; }
  if (!integ) return null;
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
//   líquido= net_received_amount − valor devolvido ao comprador
//            + cobranças devolvidas ao vendedor − créditos que voltaram pro comprador
//            (o Mercado Pago NÃO atualiza o net_received_amount depois de reembolso;
//             as cobranças trazem amounts.refunded — validado em 06/10/2026)
//   ajuste = bruto − reembolsado − tarifa − frete − taxas − líquido (0,00 quando o MP fecha a conta)
// Validado em 06/10/2026: 59,75−6,81−9,75−0,06=43,13; 36,95−4,21−(17,14−9,99)−0,04=25,55;
// 21,45−1,88−(16,94−9,99)−(3,90+0,59−3,90)=12,03.
// ------------------------------------------------------------
function analisarPagamento(mp: any) {
  const st = String(mp.status || '');
  let tarifa = 0, freteCobrado = 0, taxas = 0, creditos = 0, cobrancasDevolvidas = 0, creditosDevolvidos = 0;
  const charges: any[] = [];
  for (const c of mp.charges_details || []) {
    const orig = Number(c.amounts?.original || 0);
    const dev = Number(c.amounts?.refunded || 0);
    const v = orig - dev;
    const de = c.accounts?.from, para = c.accounts?.to;
    charges.push([c.name, c.type, de, para, orig, dev]);
    if (de === 'collector') {
      cobrancasDevolvidas += dev;
      if (c.type === 'shipping') freteCobrado += v;
      else if (String(c.name || '').startsWith('ml_')) tarifa += v;
      else taxas += v;
    } else if (para === 'collector') {
      creditos += v;
      creditosDevolvidos += dev;
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
  if (tipo === 'valido') liquido = net - reembolsado + cobrancasDevolvidas - creditosDevolvidos;
  const parcial = tipo === 'valido' && reembolsado > 0;

  const valores = tipo === 'valido'
    ? { tarifa: r2(tarifa), frete: r2(frete), taxas: r2(taxasLiq), liquido: r2(liquido),
        ajuste: r2(bruto - reembolsado - tarifa - frete - taxasLiq - liquido) }
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
    liquido_taxas_mp: r2(soma('taxas') + soma('ajuste') + soma('reembolsado')),  // inclui ajuste e reembolso: bruto − tarifa − frete − taxas = líquido
    liquido_status: validos.some((a) => a.parcial) ? 'reembolso_parcial' : 'ok',
  };
  if (lidos.some((a) => a.tipo === 'aguardando')) return { valor_liquido: null, liquido_status: 'pendente' };
  return { valor_liquido: 0, liquido_tarifa_ml: 0, liquido_frete_vendedor: 0, liquido_taxas_mp: 0, liquido_status: 'estornado' };
}

// ------------------------------------------------------------
// Líquido de UM pedido do ML a partir dos pagamentos no Mercado Pago.
// Devolve null em valor_liquido quando ainda não dá pra saber
// (pagamento pendente) — aí a venda é tentada de novo depois.
// ------------------------------------------------------------
async function calcularLiquido(order: any, token: string) {
  const pagamentos = order.payments || [];
  if (!pagamentos.length) return { valor_liquido: null, liquido_status: 'sem_pagamento' };
  const lidos: any[] = [];
  for (const p of pagamentos) {
    const resp = await fetch(`https://api.mercadopago.com/v1/payments/${p.id}`, { headers: { Authorization: `Bearer ${token}` } });
    if (resp.status === 401) return { erro401: true } as any;
    if (!resp.ok) return { valor_liquido: null, liquido_status: 'erro', detalhe: `Mercado Pago HTTP ${resp.status}` };
    lidos.push(analisarPagamento(await resp.json()));
  }
  return agregarLote3(lidos);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });

  const url = new URL(req.url);
  const limite = Math.min(Math.max(Number(url.searchParams.get('limite')) || 40, 1), 80);
  const desdeParam = url.searchParams.get('desde');
  const dias = Math.min(Math.max(Number(url.searchParams.get('dias')) || 3, 1), 30);
  const desde = desdeParam && /^\d{4}-\d{2}-\d{2}$/.test(desdeParam)
    ? new Date(desdeParam + 'T00:00:00-03:00').toISOString()
    : new Date(Date.now() - dias * 86400000).toISOString();
  const execucao = url.searchParams.get('execucao');   // ISO do início da rodada de backfill

  let consulta = supabase
    .from('pedidos_venda')
    .select('id, canal, ml_order_id')
    .not('ml_order_id', 'is', null)
    .is('valor_liquido', null)
    .eq('status', 'confirmado')
    .gte('data_pedido', desde)
    .order('data_pedido', { ascending: true })
    .limit(limite);
  if (execucao) consulta = consulta.or(`liquido_atualizado_em.is.null,liquido_atualizado_em.lt."${execucao}"`);
  // Modo automático (sem ?desde): só re-tenta vendas que o webhook JÁ tentou
  // calcular (pagamento pendente / erro). Vendas importadas antes do Lote 3
  // (liquido_status vazio) ficam de fora — essas só entram no backfill aprovado.
  if (!desdeParam) consulta = consulta.not('liquido_status', 'is', null);

  const { data: pedidos, error } = await consulta;
  if (error) {
    return new Response(JSON.stringify({ erro: error.message }), { status: 500, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
  }

  const tokens: Record<string, string | null> = {};
  const resumo = { processados: 0, preenchidos: 0, pendentes: 0, erros: 0, detalhes_erro: [] as string[] };

  async function processar(p: any) {
    resumo.processados++;
    if (!(p.canal in tokens)) tokens[p.canal] = await getAccessToken(p.canal);
    let token = tokens[p.canal];
    let atualizacao: any;

    if (!token) {
      atualizacao = { liquido_status: 'erro' };
      resumo.detalhes_erro.push(`${p.ml_order_id}: conta ${p.canal} sem token`);
    } else {
      let o = await fetch(`https://api.mercadolibre.com/orders/${p.ml_order_id}`, { headers: { Authorization: `Bearer ${token}` } });
      if (o.status === 401) {
        tokens[p.canal] = token = await getAccessToken(p.canal, true);
        if (token) o = await fetch(`https://api.mercadolibre.com/orders/${p.ml_order_id}`, { headers: { Authorization: `Bearer ${token}` } });
      }
      if (!token || !o.ok) {
        atualizacao = { liquido_status: 'erro' };
        resumo.detalhes_erro.push(`${p.ml_order_id}: pedido HTTP ${o.status}`);
      } else {
        const order = await o.json();
        let calc: any = await calcularLiquido(order, token);
        if (calc.erro401) {
          tokens[p.canal] = token = await getAccessToken(p.canal, true);
          calc = token ? await calcularLiquido(order, token) : { valor_liquido: null, liquido_status: 'erro' };
          if (calc.erro401) calc = { valor_liquido: null, liquido_status: 'erro', detalhe: 'token recusado' };
        }
        if (calc.detalhe) resumo.detalhes_erro.push(`${p.ml_order_id}: ${calc.detalhe}`);
        delete calc.detalhe;
        atualizacao = calc;
      }
    }

    atualizacao.liquido_atualizado_em = new Date().toISOString();
    const { error: errUp } = await supabase.from('pedidos_venda').update(atualizacao).eq('id', p.id);
    if (errUp) { resumo.erros++; resumo.detalhes_erro.push(`${p.ml_order_id}: ${errUp.message}`); return; }
    if (atualizacao.valor_liquido !== null && atualizacao.valor_liquido !== undefined) resumo.preenchidos++;
    else if (atualizacao.liquido_status === 'pendente') resumo.pendentes++;
    else resumo.erros++;
  }

  // 4 de cada vez, pra não sobrecarregar a API do ML
  const lista = pedidos || [];
  for (let i = 0; i < lista.length; i += 4) {
    await Promise.all(lista.slice(i, i + 4).map(processar));
  }

  // quantas ainda faltam nessa mesma janela/rodada
  let restantesQ = supabase
    .from('pedidos_venda')
    .select('id', { count: 'exact', head: true })
    .not('ml_order_id', 'is', null)
    .is('valor_liquido', null)
    .eq('status', 'confirmado')
    .gte('data_pedido', desde);
  if (execucao) restantesQ = restantesQ.or(`liquido_atualizado_em.is.null,liquido_atualizado_em.lt."${execucao}"`);
  if (!desdeParam) restantesQ = restantesQ.not('liquido_status', 'is', null);
  const { count: restantes } = await restantesQ;

  resumo.detalhes_erro = resumo.detalhes_erro.slice(0, 20);
  return new Response(JSON.stringify({ desde, ...resumo, restantes: restantes ?? null }, null, 2), {
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json; charset=utf-8' },
  });
});
