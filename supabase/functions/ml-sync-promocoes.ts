// ============================================================
// ERP E-Factory — Edge Function: ml-sync-promocoes
// Sincroniza as promoções ATIVAS (status "started") de cada anúncio das
// 3 contas Mercado Livre e grava em ml_promocoes_ativas. Mesmo padrão de
// "retrato atual" das outras sincronizações: a cada rodada a tabela dessa
// conta é refeita do zero a partir do que está ativo agora — promoção
// que terminou ou anúncio sem nenhuma promoção some da lista
// automaticamente.
//
// Endpoint oficial (doc "Gerenciar promoções" > "Consultar promoções do
// item"):
//   GET https://api.mercadolibre.com/seller-promotions/items/$ITEM_ID?app_version=v2
// Retorna TODAS as promoções associadas ao item (candidatas, pendentes e
// ativas) — aqui filtramos só as com status "started" (ativa agora).
//
// IMPORTANTE: exige a permissão funcional "Promoções, cupons e descontos"
// habilitada no app do Mercado Livre Devs Center (leitura já é suficiente
// — só usamos GET). Se essa permissão for nova pro app, as 3 contas
// precisam ser RECONECTADAS na aba Integrações depois de habilitar (o
// escopo de um token OAuth fica fixo no momento da autorização — ver
// gotcha no documento do projeto).
// ============================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

// ------------------------------------------------------------
// Proteção contra o erro intermitente do Supabase "JWT issued at future"
// (PGRST303). Esse JWT é gerado pelo próprio gateway do Supabase a partir da
// chave de serviço; quando o relógio dele fica alguns segundos à frente do
// banco, a consulta é recusada. Não dá pra corrigir o iat do
// nosso lado — então toda chamada ao Supabase passa por aqui e é repetida
// com espera crescente (até ~19s no total) antes de desistir.
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

const CANAIS = ['ml_conta1', 'ml_conta2', 'ml_conta3'] as const;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Mesma lógica de renovação automática de token usada nas outras funções.
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  const resultado: any[] = [];

  for (const canal of CANAIS) {
    let token = await getAccessToken(canal);
    if (!token) {
      resultado.push({ canal, erro: 'conta não conectada' });
      continue;
    }

    try {
      const { data: anuncios, error: erroAnuncios } = await supabase
        .from('produto_anuncios_ml')
        .select('item_id, produto_id')
        .eq('canal', canal);
      // Sem a lista de anúncios, a "lista nova" sairia vazia e o passo de
      // limpeza apagaria todas as promoções da conta — então paramos aqui.
      if (erroAnuncios) throw new Error(`Erro ao ler produto_anuncios_ml: ${erroAnuncios.message}`);

      const linhas: any[] = [];
      let itensComErro = 0;
      // Token recusado (401/403 mesmo depois de renovar) = a busca da conta
      // inteira não é confiável. Nesse caso não mexemos na tabela dessa conta.
      let tokenRecusado = false;

      for (const anuncio of anuncios || []) {
        if (!anuncio.item_id) continue;

        const urlItem = `https://api.mercadolibre.com/seller-promotions/items/${anuncio.item_id}?app_version=v2`;
        let resp = await fetch(urlItem, { headers: { Authorization: `Bearer ${token}` } });
        if (resp.status === 401) {
          // token recusado pelo ML — renova e tenta mais uma vez antes de desistir
          const novoToken = await getAccessToken(canal, true);
          if (novoToken) {
            token = novoToken;
            resp = await fetch(urlItem, { headers: { Authorization: `Bearer ${token}` } });
          }
        }

        if (resp.status === 401 || resp.status === 403) {
          tokenRecusado = true;
          break;
        }

        if (!resp.ok) {
          // Item sem nenhuma promoção configurada às vezes retorna erro —
          // não deixamos isso travar a sincronização dos outros anúncios.
          itensComErro++;
          continue;
        }

        const promocoes = await resp.json();
        if (!Array.isArray(promocoes)) continue;

        for (const p of promocoes) {
          if (p.status !== 'started') continue; // só nos interessa o que está ativo agora
          linhas.push({
            canal,
            item_id: anuncio.item_id,
            produto_id: anuncio.produto_id,
            promotion_id: p.id || null,
            tipo: p.type,
            nome: p.name || null,
            status: p.status,
            preco_promocional: p.price ?? null,
            preco_original: p.original_price ?? null,
            data_inicio: p.start_date || null,
            data_fim: p.finish_date || null,
            updated_at: new Date().toISOString(),
          });
        }
      }

      if (tokenRecusado) {
        resultado.push({ canal, erro: 'Mercado Livre recusou o token mesmo após renovar (401/403) — promoções dessa conta mantidas como estavam' });
        continue;
      }

      // Retrato atual: refaz a tabela dessa conta do zero com o que está
      // ativo agora (mesmo padrão das outras sincronizações). Só apaga
      // depois de já ter montado as linhas novas em memória, pra nunca
      // ficar sem dado nenhum se algo falhar no meio do caminho.
      const { error: erroApagar } = await supabase.from('ml_promocoes_ativas').delete().eq('canal', canal);
      if (erroApagar) throw new Error(`Erro ao limpar promoções antigas: ${erroApagar.message}`);
      if (linhas.length > 0) {
        const { error: erroGravar } = await supabase.from('ml_promocoes_ativas').insert(linhas);
        if (erroGravar) throw new Error(`Erro ao gravar promoções: ${erroGravar.message}`);
      }

      resultado.push({
        canal,
        anuncios_verificados: (anuncios || []).length,
        promocoes_ativas: linhas.length,
        itens_com_erro: itensComErro,
      });
    } catch (e) {
      resultado.push({ canal, erro: String(e) });
    }
  }

  return new Response(JSON.stringify({ resultado }, null, 2), {
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});