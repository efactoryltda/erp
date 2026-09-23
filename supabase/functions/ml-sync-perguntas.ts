// ============================================================
// ERP E-Factory — Edge Function: ml-sync-perguntas
// Sincroniza as perguntas SEM RESPOSTA ("UNANSWERED") das 3 contas e
// grava em ml_perguntas_abertas. A cada rodada, a tabela é atualizada
// pra bater com a realidade: pergunta que foi respondida (ou o anúncio
// fechou) é removida da lista automaticamente (mesmo padrão de
// "retrato atual" usado no ml-sync-full-stock).
//
// Endpoint oficial (doc "Gerenciamento de perguntas e respostas"):
//   GET https://api.mercadolibre.com/questions/search?seller_id=$SELLER_ID&api_version=4
// Auth padrão (Bearer), sem header especial. seller_id = ml_user_id
// que já temos guardado (não precisa buscar nada extra, diferente do
// advertiser_id do Ads).
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
async function getAccessToken(canal: string, forcarRenovacao = false): Promise<{ token: string; sellerId: string } | null> {
  const { data: integ, error: errInteg } = await supabase.from('integracoes_ml').select('*').eq('canal', canal).maybeSingle();
  if (errInteg) {
    // erro do banco (não é "conta não conectada") — deixa registrado pra não confundir
    console.error(`Erro ao ler integracoes_ml de ${canal}:`, errInteg.message);
    return null;
  }
  if (!integ) return null;

  const expiraEm = new Date(integ.expires_at).getTime();
  if (!forcarRenovacao && Date.now() < expiraEm - 60000) {
    return { token: integ.access_token, sellerId: integ.ml_user_id };
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

  return { token: data.access_token, sellerId: integ.ml_user_id };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  const resultado: any[] = [];

  for (const canal of CANAIS) {
    const auth = await getAccessToken(canal);
    if (!auth) {
      resultado.push({ canal, erro: 'conta não conectada' });
      continue;
    }
    let { token } = auth;
    const { sellerId } = auth;
    if (!sellerId) {
      resultado.push({ canal, erro: 'ml_user_id não encontrado em integracoes_ml' });
      continue;
    }

    try {
      // Busca o mapa item_id -> produto_id desse canal, pra já deixar
      // a pergunta ligada ao produto interno (útil pra exibir na tela).
      const { data: anuncios, error: erroAnuncios } = await supabase
        .from('produto_anuncios_ml')
        .select('item_id, produto_id')
        .eq('canal', canal);
      // sem o mapa, as perguntas seriam regravadas sem produto — melhor não mexer nessa conta
      if (erroAnuncios) throw new Error(`Erro ao ler produto_anuncios_ml: ${erroAnuncios.message}`);
      const mapaProduto = new Map<string, string>();
      for (const a of anuncios || []) {
        if (a.item_id) mapaProduto.set(a.item_id, a.produto_id);
      }

      // Pagina todas as perguntas UNANSWERED dessa conta.
      const perguntas: any[] = [];
      let offset = 0;
      const limit = 50;
      let total = Infinity;
      // Se a busca no ML falhar (mesmo no meio da paginação), a lista fica
      // incompleta: nesse caso NÃO gravamos nem apagamos nada dessa conta.
      // Antes, uma falha deixava a lista vazia e o passo de limpeza apagava
      // todas as perguntas em aberto da conta.
      let falhouBusca = false;

      while (offset < total) {
        const url = `https://api.mercadolibre.com/questions/search` +
          `?seller_id=${sellerId}&status=UNANSWERED&api_version=4&limit=${limit}&offset=${offset}`;
        let resp = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
        if (resp.status === 401) {
          // token recusado pelo ML — renova e tenta mais uma vez antes de desistir
          const novo = await getAccessToken(canal, true);
          if (novo) {
            token = novo.token;
            resp = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
          }
        }
        const dados = await resp.json();

        if (!resp.ok) {
          resultado.push({ canal, erro: `ML retornou ${resp.status}`, resposta_bruta: dados });
          falhouBusca = true;
          break;
        }

        total = typeof dados.total === 'number' ? dados.total : (dados.questions || []).length;
        const pagina = dados.questions || [];
        perguntas.push(...pagina);

        if (pagina.length === 0) break; // segurança contra loop infinito
        offset += limit;
      }

      if (falhouBusca) continue; // erro já registrado no resultado; tabela dessa conta fica como estava

      // Grava (upsert) as perguntas abertas atuais.
      let gravadas = 0;
      const idsAtuais: number[] = [];
      for (const p of perguntas) {
        idsAtuais.push(p.id);
        const linha = {
          canal,
          question_id: p.id,
          item_id: p.item_id,
          produto_id: mapaProduto.get(p.item_id) || null,
          texto: p.text,
          status: p.status,
          comprador_id: p.from?.id ? String(p.from.id) : null,
          data_pergunta: p.date_created,
          updated_at: new Date().toISOString(),
        };

        const { error: erroGravar } = await supabase
          .from('ml_perguntas_abertas')
          .upsert(linha, { onConflict: 'canal,question_id' });

        if (erroGravar) {
          console.error(`Erro ao gravar pergunta ${p.id} do canal ${canal}:`, erroGravar);
        } else {
          gravadas++;
        }
      }

      // Remove da tabela as perguntas que não estão mais em aberto
      // (foram respondidas, o anúncio fechou, etc.) — mantém a tabela
      // sempre como um "retrato" fiel do que está pendente agora.
      let removidas = 0;
      if (idsAtuais.length > 0) {
        const { data: apagadas, error: erroApagar } = await supabase
          .from('ml_perguntas_abertas')
          .delete()
          .eq('canal', canal)
          .not('question_id', 'in', `(${idsAtuais.join(',')})`)
          .select('question_id');
        if (erroApagar) {
          console.error(`Erro ao limpar perguntas antigas do canal ${canal}:`, erroApagar);
        } else {
          removidas = apagadas?.length || 0;
        }
      } else {
        // Não sobrou nenhuma pergunta em aberto nessa conta: limpa tudo.
        const { data: apagadas, error: erroApagar } = await supabase
          .from('ml_perguntas_abertas')
          .delete()
          .eq('canal', canal)
          .select('question_id');
        if (!erroApagar) removidas = apagadas?.length || 0;
      }

      resultado.push({ canal, perguntas_recebidas: perguntas.length, perguntas_gravadas: gravadas, perguntas_removidas: removidas });
    } catch (e) {
      resultado.push({ canal, erro: String(e) });
    }
  }

  return new Response(JSON.stringify({ resultado }, null, 2), {
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});