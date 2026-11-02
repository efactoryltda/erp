// ============================================================
// ERP E-Factory — Edge Function: shopee-auth  (Lote 10c)
// O botão "Conectar Shopee" do ERP abre esta função; ela monta o link
// assinado de autorização da Shopee (a Partner Key fica só aqui no
// servidor) e redireciona o navegador para a tela de login da loja.
// ?ambiente=sandbox (loja de teste) | producao (padrão)
// ============================================================
import { CALLBACK_URL, ERP_URL, urlPublica, type Ambiente } from './shopee.ts';

Deno.serve(async (req) => {
  const amb: Ambiente = new URL(req.url).searchParams.get('ambiente') === 'sandbox' ? 'sandbox' : 'producao';
  try {
    const destino = await urlPublica(amb, '/api/v2/shop/auth_partner', {
      redirect: `${CALLBACK_URL}?ambiente=${amb}`,
    });
    return new Response(null, { status: 302, headers: { Location: destino } });
  } catch (e) {
    const msg = encodeURIComponent(String((e as Error).message || e));
    return new Response(null, { status: 302, headers: { Location: `${ERP_URL}?shopee=erro&msg=${msg}` } });
  }
});
