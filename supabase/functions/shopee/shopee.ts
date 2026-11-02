// ============================================================
// ERP E-Factory — módulo comum da integração Shopee (Lote 10c)
// Copiado junto em cada Edge Function shopee-* (o deploy leva este
// arquivo como ./shopee.ts). Concentra: chaves por ambiente, assinatura
// HMAC-SHA256, chamadas à API, renovação de token e importação de pedidos.
//
// Ambientes:
//   sandbox  → SHOPEE_TEST_PARTNER_ID / SHOPEE_TEST_PARTNER_KEY, host de testes
//   producao → SHOPEE_PARTNER_ID / SHOPEE_PARTNER_KEY, host do Brasil
// Pedidos importados em sandbox entram com "SANDBOX-" no número, SEM baixa
// de estoque, e podem ser excluídos depois do teste.
// ============================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

// mesma proteção contra o PGRST303 ("JWT issued at future") das funções do ML
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

export const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
export const supabase = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  global: { fetch: fetchComRetrySupabase },
});

export const ERP_URL = 'https://efactoryltda.github.io/erp/';
export const CALLBACK_URL = `${SUPABASE_URL}/functions/v1/shopee-oauth-callback`;
export const WEBHOOK_URL = `${SUPABASE_URL}/functions/v1/shopee-webhook`;

export type Ambiente = 'sandbox' | 'producao';

export function credenciais(amb: Ambiente) {
  const sandbox = amb === 'sandbox';
  const id = Deno.env.get(sandbox ? 'SHOPEE_TEST_PARTNER_ID' : 'SHOPEE_PARTNER_ID') || '';
  const key = Deno.env.get(sandbox ? 'SHOPEE_TEST_PARTNER_KEY' : 'SHOPEE_PARTNER_KEY') || '';
  const host = (Deno.env.get(sandbox ? 'SHOPEE_TEST_HOST' : 'SHOPEE_HOST') ||
    (sandbox ? 'https://openplatform.sandbox.test-stable.shopee.sg' : 'https://openplatform.shopee.com.br')).replace(/\/$/, '');
  if (!id || !key) throw new Error(`Chaves da Shopee (${amb}) não configuradas nos Secrets do Supabase`);
  return { partnerId: Number(id), key, host };
}

export async function hmacHex(chave: string, texto: string): Promise<string> {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(chave), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(texto));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

const agora = () => Math.floor(Date.now() / 1000);

// Chamadas "públicas" (sem loja): base = partner_id + path + timestamp
export async function urlPublica(amb: Ambiente, path: string, extra: Record<string, string> = {}) {
  const c = credenciais(amb);
  const ts = agora();
  const sign = await hmacHex(c.key, `${c.partnerId}${path}${ts}`);
  const q = new URLSearchParams({ partner_id: String(c.partnerId), timestamp: String(ts), sign, ...extra });
  return `${c.host}${path}?${q}`;
}

async function lerJson(resp: Response) {
  const texto = await resp.text();
  try { return JSON.parse(texto); } catch { return { error: `HTTP ${resp.status}`, message: texto.slice(0, 300) }; }
}

export async function postPublico(amb: Ambiente, path: string, corpo: Record<string, unknown>) {
  const resp = await fetch(await urlPublica(amb, path), {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(corpo),
  });
  return lerJson(resp);
}

// ---------------- conexão (token) ----------------
export type Conexao = { ambiente: Ambiente; shopId: number; accessToken: string };

export async function salvarTokens(amb: Ambiente, shopId: number, t: any, extra: Record<string, unknown> = {}) {
  const agoraMs = Date.now();
  const { error } = await supabase.from('integracoes_shopee').upsert({
    canal: 'shopee', ambiente: amb, shop_id: shopId,
    access_token: t.access_token, refresh_token: t.refresh_token,
    access_expires_at: new Date(agoraMs + Number(t.expire_in || 14400) * 1000).toISOString(),
    refresh_expires_at: new Date(agoraMs + 30 * 24 * 3600 * 1000).toISOString(),
    updated_at: new Date().toISOString(), ...extra,
  }, { onConflict: 'canal' });
  if (error) throw new Error('Erro ao salvar tokens da Shopee: ' + error.message);
}

// Lê a conexão e renova o access_token se faltar menos de 10 min (vale 4h).
// forcar = true: renova mesmo dentro da validade (ex: a Shopee recusou o token).
export async function obterConexao(forcar = false): Promise<Conexao | null> {
  const { data: c, error } = await supabase.from('integracoes_shopee').select('*').eq('canal', 'shopee').maybeSingle();
  if (error) throw new Error('Erro ao ler integracoes_shopee: ' + error.message);
  if (!c || !c.shop_id || !c.refresh_token) return null;
  const amb = c.ambiente as Ambiente;
  const valido = c.access_expires_at && Date.now() < new Date(c.access_expires_at).getTime() - 10 * 60 * 1000;
  if (!forcar && valido) return { ambiente: amb, shopId: Number(c.shop_id), accessToken: c.access_token };

  const c2 = credenciais(amb);
  const r = await postPublico(amb, '/api/v2/auth/access_token/get', {
    refresh_token: c.refresh_token, partner_id: c2.partnerId, shop_id: Number(c.shop_id),
  });
  if (r.error || !r.access_token) throw new Error('Shopee recusou a renovação do acesso: ' + (r.message || r.error || 'sem detalhe'));
  await salvarTokens(amb, Number(c.shop_id), r);
  return { ambiente: amb, shopId: Number(c.shop_id), accessToken: r.access_token };
}

// Chamada de loja: base = partner_id + path + timestamp + access_token + shop_id
export async function getLoja(con: Conexao, path: string, params: Record<string, string> = {}) {
  const fazer = async (c: Conexao) => {
    const k = credenciais(c.ambiente);
    const ts = agora();
    const sign = await hmacHex(k.key, `${k.partnerId}${path}${ts}${c.accessToken}${c.shopId}`);
    const q = new URLSearchParams({
      partner_id: String(k.partnerId), timestamp: String(ts), access_token: c.accessToken,
      shop_id: String(c.shopId), sign, ...params,
    });
    return lerJson(await fetch(`${k.host}${path}?${q}`));
  };
  let r = await fazer(con);
  if (r.error === 'invalid_access_token' || r.error === 'error_auth') {
    const nova = await obterConexao(true);
    if (nova) r = await fazer(nova);
  }
  return r;
}

// ---------------- pedidos ----------------
const CAMPOS_DETALHE = [
  'buyer_username', 'item_list', 'pay_time', 'pickup_done_time', 'fulfillment_flag',
  'shipping_carrier', 'checkout_shipping_carrier', 'cancel_by', 'cancel_reason',
  'invoice_data', 'total_amount', 'package_list',
].join(',');

export async function detalharPedidos(con: Conexao, orderSns: string[]) {
  const pedidos: any[] = [];
  for (let i = 0; i < orderSns.length; i += 50) {
    const lote = orderSns.slice(i, i + 50);
    const r = await getLoja(con, '/api/v2/order/get_order_detail', {
      order_sn_list: lote.join(','), response_optional_fields: CAMPOS_DETALHE,
    });
    if (r.error) throw new Error(`get_order_detail: ${r.error} ${r.message || ''}`);
    pedidos.push(...(r.response?.order_list || []));
  }
  return pedidos;
}

// Lista os order_sn atualizados numa janela (máx. 15 dias por consulta na Shopee)
export async function listarAtualizados(con: Conexao, desdeSeg: number, ateSeg: number) {
  const sns: string[] = [];
  let cursor = '';
  for (let pagina = 0; pagina < 20; pagina++) {
    const r = await getLoja(con, '/api/v2/order/get_order_list', {
      time_range_field: 'update_time', time_from: String(desdeSeg), time_to: String(ateSeg),
      page_size: '100', cursor, response_optional_fields: 'order_status',
    });
    if (r.error) throw new Error(`get_order_list: ${r.error} ${r.message || ''}`);
    for (const o of r.response?.order_list || []) sns.push(String(o.order_sn));
    if (!r.response?.more) break;
    cursor = String(r.response.next_cursor || '');
  }
  return sns;
}

const sufixoSandbox = (amb: Ambiente, sn: string) => (amb === 'sandbox' ? `SANDBOX-${sn}` : sn);

function modalidade(o: any): string | null {
  const flag = String(o.fulfillment_flag || '').toLowerCase();
  if (flag.includes('shopee')) return 'full';     // fulfilled_by_shopee
  return null;                                     // o banco põe "envio_proprio" (ver mapeamento após 1º pedido real)
}

// Aplica UM pedido da Shopee no ERP. Idempotente: pode ser chamado várias vezes.
// Retorna o que fez (pra resumo/log).
export async function aplicarPedido(con: Conexao, o: any, simular = false): Promise<string> {
  const amb = con.ambiente;
  const sn = sufixoSandbox(amb, String(o.order_sn));
  const st = String(o.order_status || '');
  const pago = !!o.pay_time;

  const { data: existente, error: errEx } = await supabase.from('pedidos_venda')
    .select('id, status, shopee_status, local_baixa_estoque').eq('shopee_order_sn', sn).maybeSingle();
  if (errEx) throw new Error('leitura ERP: ' + errEx.message);

  if (!existente) {
    if (st === 'UNPAID') return 'ignorado_nao_pago';
    if (st === 'CANCELLED' && !pago) return 'ignorado_cancelado_sem_pagamento';
    if (simular) return `importaria (${st})`;

    const fbs = modalidade(o) === 'full';
    const cancelado = st === 'CANCELLED';
    const itens = (o.item_list || []).map((i: any) => ({
      sku: String(i.model_sku || i.item_sku || ''),
      quantidade: Number(i.model_quantity_purchased || 0),
      preco_unitario: Number(i.model_discounted_price ?? i.model_original_price ?? 0),
      shopee_item_id: i.item_id != null ? String(i.item_id) : null,
      shopee_model_id: i.model_id != null ? String(i.model_id) : null,
    }));
    const obs = [
      amb === 'sandbox' ? 'TESTE (sandbox Shopee) — pode excluir' : 'Importado automaticamente da Shopee',
      cancelado ? 'Já veio cancelado — sem baixa de estoque' : '',
      fbs ? 'Full Shopee — estoque Full Shopee ainda não existe no ERP, sem baixa' : '',
    ].filter(Boolean).join(' | ');
    const { data, error } = await supabase.rpc('importar_pedido_shopee', {
      p_pedido: {
        shopee_order_sn: sn, shopee_status: st, cliente: o.buyer_username || '',
        data_pedido: new Date(Number(o.create_time) * 1000).toISOString(),
        status: cancelado ? 'cancelado' : 'confirmado', modalidade_envio: modalidade(o),
        local_baixa_estoque: 'fisico', observacao: obs,
      },
      p_itens: itens,
      p_baixar_estoque: amb === 'producao' && !fbs,
    });
    if (error) throw new Error(`importar ${sn}: ${error.message}`);
    return data?.novo ? `importado${data.itens_sem_produto ? ` (${data.itens_sem_produto} item sem produto)` : ''}` : 'ja_existia';
  }

  // já existe: acompanha status e cancelamento
  let feito = 'sem_mudanca';
  if (existente.shopee_status !== st) {
    if (simular) return `atualizaria status ${existente.shopee_status} → ${st}`;
    await supabase.from('pedidos_venda').update({ shopee_status: st, updated_at: new Date().toISOString() }).eq('id', existente.id);
    feito = `status ${existente.shopee_status} → ${st}`;
  }
  if (st === 'CANCELLED' && existente.status === 'confirmado') {
    if (simular) return 'cancelaria no ERP';
    // estoque só volta se saiu do físico e o pacote nunca foi coletado
    const devolver = existente.local_baixa_estoque === 'fisico' && !o.pickup_done_time;
    const { error } = await supabase.rpc('registrar_cancelamento_shopee', { p_pedido_id: existente.id, p_devolver_estoque: devolver });
    if (error) throw new Error(`cancelar ${sn}: ${error.message}`);
    feito = devolver ? 'cancelado (estoque devolvido)' : 'cancelado (estoque não mexido)';
  }
  return feito;
}

export function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj, null, 2), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    },
  });
}
