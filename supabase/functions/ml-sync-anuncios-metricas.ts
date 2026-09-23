// ============================================================
// ERP E-Factory — Edge Function: ml-sync-anuncios-metricas
// Sincroniza, uma vez por dia, um retrato de desempenho de cada anúncio
// das 3 contas: visitas, qualidade da publicação (e o que falta
// melhorar), avaliações dos compradores, e status de concorrência de
// preço (só relevante pra anúncios em Catálogo — pros outros fica
// "não aplicável"). Ao contrário de Perguntas/Promoções, essa tabela NÃO
// é um "retrato atual" que se apaga — é histórico (uma linha por
// anúncio + dia), pra dar pra ver tendência.
//
// Cada anúncio pode falhar em uma consulta (ex: sem avaliação ainda,
// ou não é de catálogo) sem travar as outras — cada campo é buscado de
// forma independente e fica null se não der certo.
//
// Endpoints usados (doc "Métricas e Tendências" e "Competição"):
//   GET /items/{ITEM_ID}/visits/time_window?last=1&unit=day
//   GET /item/{ITEM_ID}/performance            (anúncio clássico, MLB...)
//   GET /user-product/{ITEM_ID}/performance    (user product, MLBU...)
//   GET /reviews/item/{ITEM_ID}?limit=1
//   GET /items/{ITEM_ID}/price_to_win?version=v2
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

// As buscas por anúncio abaixo engolem qualquer erro (viram null) — então um
// token recusado gravaria o dia inteiro com campos vazios, sem avisar. Por
// isso o token é conferido UMA vez por conta antes do loop (GET /users/me,
// consulta leve): se o ML recusar (401), renova e confere de novo; se ainda
// assim falhar, a conta é pulada e o erro aparece no resultado.
async function tokenValido(canal: string, token: string): Promise<string | null> {
  const conferir = (t: string) =>
    fetch('https://api.mercadolibre.com/users/me', { headers: { Authorization: `Bearer ${t}` } });
  let resp = await conferir(token);
  if (resp.status !== 401) {
    await resp.body?.cancel();
    return token; // ok (ou erro que não é de token — segue como antes)
  }
  await resp.body?.cancel();
  const novoToken = await getAccessToken(canal, true);
  if (!novoToken) return null;
  resp = await conferir(novoToken);
  await resp.body?.cancel();
  return resp.status === 401 ? null : novoToken;
}

// "MLBU..." (site de 3 letras + U) = user_product_id. "MLB..." = item clássico.
function ehUserProduct(itemId: string): boolean {
  return /^[A-Z]{3}U/.test(itemId);
}

async function buscarVisitas(itemId: string, token: string): Promise<number | null> {
  try {
    const resp = await fetch(
      `https://api.mercadolibre.com/items/${itemId}/visits/time_window?last=1&unit=day`,
      { headers: { Authorization: `Bearer ${token}` } }
    );
    if (!resp.ok) return null;
    const data = await resp.json();
    return typeof data.total_visits === 'number' ? data.total_visits : null;
  } catch {
    return null;
  }
}

async function buscarQualidade(itemId: string, token: string) {
  const url = ehUserProduct(itemId)
    ? `https://api.mercadolibre.com/user-product/${itemId}/performance`
    : `https://api.mercadolibre.com/item/${itemId}/performance`;
  try {
    const resp = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    if (!resp.ok) return { score: null, level: null, pendencias: null };
    const data = await resp.json();

    // Junta os títulos de todas as "rules" ainda PENDING como lista de
    // pendências legível — é justamente o material mais útil pro agente
    // sugerir "o que melhorar nesse anúncio".
    const pendencias: string[] = [];
    for (const bucket of data.buckets || []) {
      for (const variable of bucket.variables || []) {
        if (variable.status !== 'PENDING') continue;
        for (const rule of variable.rules || []) {
          if (rule.status === 'PENDING' && rule.wordings?.title) {
            pendencias.push(rule.wordings.title);
          }
        }
      }
    }

    return {
      score: typeof data.score === 'number' ? data.score : null,
      level: data.level_wording || data.level || null,
      pendencias: pendencias.length > 0 ? pendencias : null,
    };
  } catch {
    return { score: null, level: null, pendencias: null };
  }
}

async function buscarAvaliacoes(itemId: string, token: string) {
  try {
    const resp = await fetch(
      `https://api.mercadolibre.com/reviews/item/${itemId}?limit=1`,
      { headers: { Authorization: `Bearer ${token}` } }
    );
    if (!resp.ok) return { media: null, total: null };
    const data = await resp.json();
    return {
      media: typeof data.rating_average === 'number' ? data.rating_average : null,
      total: typeof data.paging?.total === 'number' ? data.paging.total : null,
    };
  } catch {
    return { media: null, total: null };
  }
}

async function buscarConcorrencia(itemId: string, token: string) {
  try {
    const resp = await fetch(
      `https://api.mercadolibre.com/items/${itemId}/price_to_win?version=v2`,
      { headers: { Authorization: `Bearer ${token}` } }
    );
    if (!resp.ok) return { ehCatalogo: false, status: null, motivo: null, precoAtual: null, precoParaGanhar: null };
    const data = await resp.json();
    const motivos: string[] = data.reason || [];
    const naoEhCatalogo = motivos.includes('item_not_opted_in') || !data.catalog_product_id;

    if (naoEhCatalogo) {
      return { ehCatalogo: false, status: null, motivo: null, precoAtual: data.current_price ?? null, precoParaGanhar: null };
    }

    return {
      ehCatalogo: true,
      status: data.status || null,
      motivo: motivos.length > 0 ? motivos : null,
      precoAtual: typeof data.current_price === 'number' ? data.current_price : null,
      precoParaGanhar: typeof data.price_to_win === 'number' ? data.price_to_win : null,
    };
  } catch {
    return { ehCatalogo: false, status: null, motivo: null, precoAtual: null, precoParaGanhar: null };
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  // Data de referência do snapshot, no horário de Brasília (UTC-3, sem horário
  // de verão desde 2019). Antes usava a data UTC: um sync manual depois das
  // 21h gravava a linha com a data de AMANHÃ.
  const hoje = new Date(Date.now() - 3 * 60 * 60 * 1000).toISOString().slice(0, 10);
  const resultado: any[] = [];

  for (const canal of CANAIS) {
    const tokenInicial = await getAccessToken(canal);
    if (!tokenInicial) {
      resultado.push({ canal, erro: 'conta não conectada' });
      continue;
    }
    const token = await tokenValido(canal, tokenInicial);
    if (!token) {
      resultado.push({ canal, erro: 'Mercado Livre recusou o token mesmo após renovar (401) — métricas dessa conta não foram gravadas hoje' });
      continue;
    }

    try {
      const { data: anuncios, error: erroAnuncios } = await supabase
        .from('produto_anuncios_ml')
        .select('item_id, produto_id')
        .eq('canal', canal);
      if (erroAnuncios) throw new Error(`Erro ao ler produto_anuncios_ml: ${erroAnuncios.message}`);

      let gravados = 0;
      let comErro = 0;

      for (const anuncio of anuncios || []) {
        if (!anuncio.item_id) continue;

        const [visitas, qualidade, avaliacoes, concorrencia] = await Promise.all([
          buscarVisitas(anuncio.item_id, token),
          buscarQualidade(anuncio.item_id, token),
          buscarAvaliacoes(anuncio.item_id, token),
          buscarConcorrencia(anuncio.item_id, token),
        ]);

        const linha = {
          canal,
          item_id: anuncio.item_id,
          produto_id: anuncio.produto_id,
          data: hoje,
          visitas,
          quality_score: qualidade.score,
          quality_level: qualidade.level,
          quality_pendencias: qualidade.pendencias,
          rating_average: avaliacoes.media,
          total_avaliacoes: avaliacoes.total,
          eh_catalogo: concorrencia.ehCatalogo,
          status_concorrencia: concorrencia.status,
          motivo_concorrencia: concorrencia.motivo,
          preco_atual: concorrencia.precoAtual,
          price_to_win: concorrencia.precoParaGanhar,
          updated_at: new Date().toISOString(),
        };

        const { error: erroGravar } = await supabase
          .from('ml_anuncios_metricas')
          .upsert(linha, { onConflict: 'canal,item_id,data' });

        if (erroGravar) {
          console.error(`Erro ao gravar métricas do anúncio ${anuncio.item_id} (${canal}):`, erroGravar);
          comErro++;
        } else {
          gravados++;
        }
      }

      resultado.push({ canal, anuncios_verificados: (anuncios || []).length, gravados, com_erro: comErro });
    } catch (e) {
      resultado.push({ canal, erro: String(e) });
    }
  }

  return new Response(JSON.stringify({ data_referencia: hoje, resultado }, null, 2), {
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});