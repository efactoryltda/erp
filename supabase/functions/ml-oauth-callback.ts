// ============================================================
// ERP E-Factory — Edge Function: ml-oauth-callback
// Recebe o retorno do login autorizado do Mercado Livre, troca o código
// por um token de acesso, e guarda a conexão da conta no banco.
// ============================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const code = url.searchParams.get('code');
  const state = url.searchParams.get('state'); // ml_conta1 | ml_conta2 | ml_conta3
  const errorParam = url.searchParams.get('error');

  if (errorParam) {
    return new Response(paginaResposta('❌ Autorização cancelada', 'Você cancelou ou negou a autorização no Mercado Livre. Pode fechar esta aba e tentar de novo.'), {
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  if (!code || !state) {
    return new Response(paginaResposta('❌ Erro', 'Faltou informação no retorno do Mercado Livre (code ou state). Tente conectar de novo.'), {
      status: 400,
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  const clientId = Deno.env.get('ML_CLIENT_ID')!;
  const clientSecret = Deno.env.get('ML_CLIENT_SECRET')!;
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const redirectUri = `${supabaseUrl}/functions/v1/ml-oauth-callback`;

  const tokenResp = await fetch('https://api.mercadolibre.com/oauth/token', {
    method: 'POST',
    headers: {
      accept: 'application/json',
      'content-type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: clientId,
      client_secret: clientSecret,
      code,
      redirect_uri: redirectUri,
    }),
  });

  const tokenData = await tokenResp.json();

  if (!tokenResp.ok) {
    console.error('Erro ao trocar código por token:', tokenData);
    return new Response(paginaResposta('❌ Erro ao conectar', 'O Mercado Livre recusou a autorização. Detalhe técnico: ' + JSON.stringify(tokenData)), {
      status: 400,
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  const supabase = createClient(supabaseUrl, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  const expiresAt = new Date(Date.now() + tokenData.expires_in * 1000).toISOString();

  // busca o nome da conta pra facilitar identificação na tela de Integrações
  let nickname: string | null = null;
  try {
    const userResp = await fetch(`https://api.mercadolibre.com/users/${tokenData.user_id}`, {
      headers: { Authorization: `Bearer ${tokenData.access_token}` },
    });
    if (userResp.ok) {
      const userData = await userResp.json();
      nickname = userData.nickname || null;
    }
  } catch (e) {
    console.error('Erro ao buscar nickname da conta:', e);
  }

  const { error: dbError } = await supabase.from('integracoes_ml').upsert(
    {
      canal: state,
      ml_user_id: String(tokenData.user_id),
      ml_nickname: nickname,
      access_token: tokenData.access_token,
      refresh_token: tokenData.refresh_token,
      expires_at: expiresAt,
      conectado_em: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    { onConflict: 'canal' }
  );

  if (dbError) {
    console.error('Erro ao salvar conexão:', dbError);
    return new Response(paginaResposta('❌ Erro ao salvar', 'A autorização funcionou, mas não consegui salvar no banco. Detalhe: ' + dbError.message), {
      status: 500,
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  return new Response(paginaResposta('✅ Conta conectada!', `Conta identificada como: <strong>${nickname || 'nome não disponível'}</strong>.<br>Pode fechar esta aba e voltar pro ERP.`), {
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
});

function paginaResposta(titulo: string, mensagem: string): string {
  return `<!DOCTYPE html>
<html lang="pt-BR"><head><meta charset="UTF-8"><title>Mercado Livre - E-Factory ERP</title></head>
<body style="font-family:-apple-system,sans-serif;text-align:center;padding:80px 20px;background:#f5f6f8;">
  <h2 style="color:#1c2536;">${titulo}</h2>
  <p style="color:#6b7280;font-size:16px;">${mensagem}</p>
</body></html>`;
}
