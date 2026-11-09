// ============================================================
// ERP E-Factory — Edge Function: shopee-webhook  (Lote 10c, ajuste 10d)
// Recebe o aviso (Push) da Shopee. A Shopee exige resposta 2xx em até
// 3 segundos, então respondemos NA HORA e processamos em segundo plano
// (EdgeRuntime.waitUntil).
// Para mudança de status de pedido (code 3) o pedido é relido na API com
// o NOSSO token e aplicado no ERP — nada é gravado a partir do corpo do
// aviso, então um aviso falso não consegue inserir nada.
// Assinatura: HMAC-SHA256(SHOPEE_PUSH_KEY, url + "|" + corpo) no header
// Authorization — só registrada no log se não bater.
// ============================================================
// O módulo comum (que carrega o cliente do Supabase) só é importado DEPOIS de
// responder, pra função "acordar" rápido e caber nos 3 segundos da Shopee.
const WEBHOOK_URL = `${Deno.env.get('SUPABASE_URL')}/functions/v1/shopee-webhook`;

async function hmacHex(chave: string, texto: string): Promise<string> {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(chave), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(texto));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function processar(corpo: string, assinatura: string) {
  try {
    const msg = JSON.parse(corpo || '{}');
    const chavePush = Deno.env.get('SHOPEE_PUSH_KEY') || '';
    if (chavePush) {
      const esperado = await hmacHex(chavePush, `${WEBHOOK_URL}|${corpo}`);
      if (assinatura !== esperado) console.warn('Assinatura do aviso não confere (o pedido é relido na API mesmo assim)');
    }
    if (Number(msg.code) !== 3) return;                 // só status de pedido por enquanto
    const sn = String(msg.data?.ordersn || msg.data?.order_sn || '');
    if (!sn) return;
    const { aplicarPedido, detalharPedidos, obterConexao } = await import('./shopee.ts');
    const con = await obterConexao();
    if (!con) { console.error('Aviso da Shopee sem loja conectada'); return; }
    if (Number(msg.shop_id) !== con.shopId) { console.warn('Aviso de outra loja ignorado:', msg.shop_id); return; }
    const [pedido] = await detalharPedidos(con, [sn]);
    if (pedido) console.log('shopee-webhook', sn, await aplicarPedido(con, pedido));
  } catch (e) {
    console.error('Erro no webhook da Shopee:', e, corpo.slice(0, 500));
  }
}

Deno.serve(async (req) => {
  const corpo = await req.text().catch(() => '');
  const tarefa = processar(corpo, req.headers.get('authorization') || '');
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(tarefa); else await tarefa;
  return new Response(null, { status: 200 });
});
