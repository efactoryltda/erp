// ============================================================
// ERP E-Factory — Edge Function: shopee-webhook  (Lote 10c)
// Recebe o aviso (Push) da Shopee. Para mudança de status de pedido
// (code 3) busca o pedido na API com o NOSSO token e aplica no ERP.
// Mesmo que alguém mande um aviso falso, nada é gravado a partir do
// corpo do aviso: o pedido sempre é lido de novo na Shopee.
// Responde sempre 200 com corpo vazio (exigência da Shopee).
// ============================================================
import { WEBHOOK_URL, aplicarPedido, credenciais, detalharPedidos, hmacHex, obterConexao } from './shopee.ts';

const ok = () => new Response(null, { status: 200 });

Deno.serve(async (req) => {
  let corpo = '';
  try {
    corpo = await req.text();
    const msg = JSON.parse(corpo || '{}');
    const con = await obterConexao();
    if (!con) { console.error('Aviso da Shopee sem loja conectada'); return ok(); }
    if (Number(msg.shop_id) !== con.shopId) { console.warn('Aviso de outra loja ignorado:', msg.shop_id); return ok(); }

    // assinatura: HMAC-SHA256(partner_key, url + "|" + corpo) — só registra se não bater
    try {
      const esperado = await hmacHex(credenciais(con.ambiente).key, `${WEBHOOK_URL}|${corpo}`);
      if ((req.headers.get('authorization') || '') !== esperado) console.warn('Assinatura do aviso não confere (seguindo: o pedido é relido na API)');
    } catch (_) { /* sem chave: segue */ }

    if (Number(msg.code) !== 3) return ok();           // só status de pedido por enquanto
    const sn = String(msg.data?.ordersn || msg.data?.order_sn || '');
    if (!sn) return ok();
    const [pedido] = await detalharPedidos(con, [sn]);
    if (pedido) console.log('shopee-webhook', sn, await aplicarPedido(con, pedido));
  } catch (e) {
    console.error('Erro no webhook da Shopee:', e, corpo.slice(0, 500));
  }
  return ok();
});
