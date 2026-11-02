// ============================================================
// ERP E-Factory — Edge Function: shopee-oauth-callback  (Lote 10c)
// A Shopee volta pra cá depois que a loja autoriza (?code=&shop_id=).
// Troca o code (vale 10 min, uso único) por access/refresh token, lê o
// nome e a validade da autorização da loja, grava em integracoes_shopee e
// devolve o navegador pro ERP com ?shopee=conectado (ou erro).
// ============================================================
import { ERP_URL, credenciais, getLoja, postPublico, salvarTokens, supabase, type Ambiente } from './shopee.ts';

const voltar = (q: string) => new Response(null, { status: 302, headers: { Location: `${ERP_URL}?${q}` } });

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const amb: Ambiente = url.searchParams.get('ambiente') === 'sandbox' ? 'sandbox' : 'producao';
  const code = url.searchParams.get('code');
  const shopId = Number(url.searchParams.get('shop_id') || 0);
  if (!code || !shopId) {
    return voltar('shopee=erro&msg=' + encodeURIComponent('A Shopee não devolveu a loja autorizada (use a conta principal da loja, não subconta).'));
  }
  try {
    const c = credenciais(amb);
    const t = await postPublico(amb, '/api/v2/auth/token/get', { code, shop_id: shopId, partner_id: c.partnerId });
    if (t.error || !t.access_token) throw new Error('Shopee recusou o código: ' + (t.message || t.error || 'sem detalhe'));
    await salvarTokens(amb, shopId, t, { conectado_em: new Date().toISOString() });

    const info = await getLoja({ ambiente: amb, shopId, accessToken: t.access_token }, '/api/v2/shop/get_shop_info');
    if (!info.error) {
      await supabase.from('integracoes_shopee').update({
        shop_name: info.shop_name || null,
        autorizacao_expira_em: info.expire_time ? new Date(Number(info.expire_time) * 1000).toISOString() : null,
      }).eq('canal', 'shopee');
    } else {
      console.error('get_shop_info:', info);
    }
    return voltar(`shopee=conectado&ambiente=${amb}`);
  } catch (e) {
    console.error('shopee-oauth-callback:', e);
    return voltar('shopee=erro&msg=' + encodeURIComponent(String((e as Error).message || e)));
  }
});
