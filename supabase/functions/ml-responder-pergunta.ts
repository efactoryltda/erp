// ============================================================
// ERP E-Factory — Edge Function: ml-responder-pergunta
// Recebe uma resposta digitada no ERP e envia pro Mercado Livre.
// Body esperado (POST): { "canal": "ml_conta1", "question_id": 123, "texto": "..." }
//
// Se o Mercado Livre aceitar a resposta, a pergunta é removida de
// ml_perguntas_abertas na hora (não precisa esperar a próxima
// sincronização) — assim ela some da tela do ERP imediatamente.
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
  if (!resp.ok) return null;

  const expiresAt = new Date(Date.now() + data.expires_in * 1000).toISOString();
  await supabase.from('integracoes_ml').update({
    access_token: data.access_token, refresh_token: data.refresh_token, expires_at: expiresAt, updated_at: new Date().toISOString(),
  }).eq('canal', canal);

  return data.access_token;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  try {
    const { canal, question_id, texto } = await req.json();
    if (!canal || !question_id || !texto) {
      return new Response(JSON.stringify({ ok: false, erro: 'Faltou canal, question_id ou texto.' }), {
        status: 400,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    let token = await getAccessToken(canal);
    if (!token) {
      return new Response(JSON.stringify({ ok: false, erro: 'Conta não conectada ou token inválido.' }), {
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const enviarResposta = (t: string) =>
      fetch('https://api.mercadolibre.com/answers', {
        method: 'POST',
        headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ question_id, text: texto }),
      });

    let resp = await enviarResposta(token);
    if (resp.status === 401) {
      // Token recusado: o ML NÃO registrou a resposta, então é seguro reenviar.
      // Renova o token e tenta mais uma vez antes de devolver erro pra tela.
      const novoToken = await getAccessToken(canal, true);
      if (novoToken) {
        await resp.body?.cancel();
        token = novoToken;
        resp = await enviarResposta(token);
      }
      // sem token novo: segue com a resposta 401 original, que vira erro na tela
    }
    const dados = await resp.json();

    if (!resp.ok) {
      return new Response(JSON.stringify({
        ok: false,
        erro: `Mercado Livre retornou ${resp.status}: ${dados.message || JSON.stringify(dados)}`,
      }), {
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    // Deu certo — remove da lista de perguntas em aberto na hora (mesmo
    // padrão de "retrato atual" que a sincronização automática usa).
    const { error: erroApagar } = await supabase.from('ml_perguntas_abertas').delete().eq('canal', canal).eq('question_id', question_id);
    if (erroApagar) {
      // A resposta JÁ foi enviada ao ML — só não saiu da lista local; a próxima
      // sincronização de perguntas remove. Não é motivo pra mostrar erro na tela.
      console.error(`Resposta enviada, mas falhou ao tirar a pergunta ${question_id} da lista:`, erroApagar.message);
    }

    return new Response(JSON.stringify({ ok: true }), {
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, erro: String(e) }), {
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
});