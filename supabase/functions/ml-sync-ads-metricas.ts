// ============================================================
// ERP E-Factory — Edge Function: ml-sync-ads-metricas
// Sincroniza as métricas diárias das campanhas de Product Ads (Mercado
// Ads) das 3 contas, e grava em ml_ads_metricas_diarias.
//
// Endpoint confirmado na documentação oficial (página "Product Ads para
// Catálogo e User Products"):
//   GET /advertising/$ADVERTISER_SITE_ID/advertisers/$ADVERTISER_ID/product_ads/campaigns/search
// com header 'api-version: 2'. O site_id (ex: MLB) vem junto na resposta
// da consulta de advertisers — por isso guardamos os dois.
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

// Mesma lógica de renovação automática de token usada em ml-sync-full-stock
// e ml-webhook — se o token estiver perto de expirar, renova sozinha.
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

// Busca o advertiser_id + site_id da conta (IDs específicos do Mercado
// Ads, diferentes do ml_user_id) e salva em integracoes_ml pra não
// precisar buscar de novo toda vez.
async function getAdvertiser(canal: string, token: string): Promise<{ advertiserId: string; siteId: string } | null> {
  const { data: integ } = await supabase
    .from('integracoes_ml')
    .select('ml_advertiser_id, ml_advertiser_site_id')
    .eq('canal', canal)
    .maybeSingle();
  if (integ?.ml_advertiser_id && integ?.ml_advertiser_site_id) {
    return { advertiserId: integ.ml_advertiser_id, siteId: integ.ml_advertiser_site_id };
  }

  const resp = await fetch('https://api.mercadolibre.com/advertising/advertisers?product_id=PADS', {
    headers: { Authorization: `Bearer ${token}`, 'Api-Version': '2' },
  });
  const dados = await resp.json();
  if (!resp.ok) {
    console.error(`Erro ao buscar advertiser_id do canal ${canal}:`, dados);
    return null;
  }

  const lista = Array.isArray(dados) ? dados : dados.advertisers || dados.results || [];
  const advertiserId = lista[0]?.advertiser_id ? String(lista[0].advertiser_id) : null;
  const siteId = lista[0]?.site_id ? String(lista[0].site_id) : null;
  if (!advertiserId || !siteId) {
    console.error(`Advertiser/site_id não encontrado pro canal ${canal}. Resposta:`, dados);
    return null;
  }

  await supabase.from('integracoes_ml').update({ ml_advertiser_id: advertiserId, ml_advertiser_site_id: siteId }).eq('canal', canal);
  return { advertiserId, siteId };
}

// Ontem no horário de Brasília (UTC-3, sem horário de verão desde 2019), em
// formato YYYY-MM-DD. Antes usava a data UTC, que só coincidia com Brasília de
// madrugada: um sync manual depois das 21h gravava o dia de HOJE (incompleto)
// no lugar de ontem.
function dataOntem(): string {
  const d = new Date(Date.now() - 3 * 60 * 60 * 1000);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

const METRICAS = 'clicks,prints,cost,cpc,ctr,acos,roas,direct_amount,indirect_amount,total_amount';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  // Permite passar um período customizado pra testes/backfill:
  // POST { "date_from": "2026-09-01", "date_to": "2026-09-04" }
  let dateFrom = dataOntem();
  let dateTo = dataOntem();
  try {
    const body = await req.json();
    if (body?.date_from) dateFrom = body.date_from;
    if (body?.date_to) dateTo = body.date_to;
  } catch {
    // sem corpo / corpo vazio — usa o padrão (ontem)
  }

  const resultado: any[] = [];

  for (const canal of CANAIS) {
    let token = await getAccessToken(canal);
    if (!token) {
      resultado.push({ canal, erro: 'conta não conectada' });
      continue;
    }

    const advertiser = await getAdvertiser(canal, token);
    if (!advertiser) {
      resultado.push({ canal, erro: 'não foi possível obter advertiser_id/site_id (veja os logs da função)' });
      continue;
    }
    const { advertiserId, siteId } = advertiser;

    try {
      const url = `https://api.mercadolibre.com/advertising/${siteId}/advertisers/${advertiserId}/product_ads/campaigns/search` +
        `?limit=100&offset=0&date_from=${dateFrom}&date_to=${dateTo}&metrics=${METRICAS}`;

      let resp = await fetch(url, {
        headers: { Authorization: `Bearer ${token}`, 'api-version': '2' },
      });
      if (resp.status === 401) {
        // token recusado pelo ML — renova e tenta mais uma vez antes de desistir
        const novoToken = await getAccessToken(canal, true);
        if (novoToken) {
          token = novoToken;
          resp = await fetch(url, {
            headers: { Authorization: `Bearer ${token}`, 'api-version': '2' },
          });
        }
      }
      const dados = await resp.json();

      if (!resp.ok) {
        resultado.push({ canal, advertiser_id: advertiserId, erro: `ML retornou ${resp.status}`, resposta_bruta: dados });
        continue;
      }

      const campanhas = dados.results || dados.campaigns || (Array.isArray(dados) ? dados : []);

      if (!Array.isArray(campanhas) || campanhas.length === 0) {
        resultado.push({ canal, advertiser_id: advertiserId, aviso: 'nenhuma campanha retornada', resposta_bruta: dados });
        continue;
      }

      let gravadas = 0;
      for (const campanha of campanhas) {
        const m = campanha.metrics || {};
        const linha = {
          canal,
          advertiser_id: advertiserId,
          campaign_id: String(campanha.id ?? campanha.campaign_id),
          campaign_name: campanha.name ?? campanha.campaign_name ?? null,
          data: dateTo, // se vier mais de um dia na resposta e precisarmos separar por dia, ajustamos aqui depois de ver o formato real
          impressoes: m.prints ?? m.impressions ?? null,
          cliques: m.clicks ?? null,
          custo: m.cost ?? null,
          ctr: m.ctr ?? null,
          acos: m.acos ?? null,
          roas: m.roas ?? null,
          vendas_diretas: m.direct_amount ?? null,
          vendas_indiretas: m.indirect_amount ?? null,
          vendas_totais: m.total_amount ?? null,
          metrics_raw: m,
          updated_at: new Date().toISOString(),
        };

        const { error: erroGravar } = await supabase
          .from('ml_ads_metricas_diarias')
          .upsert(linha, { onConflict: 'canal,campaign_id,data' });

        if (erroGravar) {
          console.error(`Erro ao gravar campanha ${linha.campaign_id} do canal ${canal}:`, erroGravar);
        } else {
          gravadas++;
        }
      }

      resultado.push({ canal, advertiser_id: advertiserId, campanhas_recebidas: campanhas.length, campanhas_gravadas: gravadas });
    } catch (e) {
      resultado.push({ canal, advertiser_id: advertiserId, erro: String(e) });
    }
  }

  return new Response(JSON.stringify({ periodo: { date_from: dateFrom, date_to: dateTo }, resultado }, null, 2), {
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});