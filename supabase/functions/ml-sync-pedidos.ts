// ============================================================
// ERP E-Factory — Edge Function: ml-sync-pedidos  (Lote 9)
// Rede de segurança do webhook. A cada 15 min (pg_cron) olha, nas 3
// contas do Mercado Livre, os pedidos atualizados nas últimas horas e
// reenvia ao ml-webhook só os que:
//   • ainda NÃO estão no ERP (aviso do ML se perdeu), ou
//   • foram cancelados no ML mas seguem "confirmado" no ERP.
// Toda a regra de importação (estoque, Full/Flex, líquido, cancelamento)
// continua num lugar só: o ml-webhook. Esta função não grava nada direto.
//
// Parâmetro opcional: ?horas=N (janela, padrão 3, máximo 72).
// ============================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

// mesma proteção contra o PGRST303 ("JWT issued at future") do ml-webhook
const ESPERAS_RETRY_SUPABASE_MS = [300, 1000, 2500, 5000, 10000];
async function fetchComRetrySupabase(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  for (let tentativa = 0; ; tentativa++) {
    const resp = await fetch(input, init);
    if (resp.status !== 401 || tentativa >= ESPERAS_RETRY_SUPABASE_MS.length) return resp;
    const corpo = await resp.clone().text();
    if (!corpo.includes('PGRST303') && !/issued at future/i.test(corpo)) return resp;
    await new Promise((r) => setTimeout(r, ESPERAS_RETRY_SUPABASE_MS[tentativa]));
  }
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const supabase = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  global: { fetch: fetchComRetrySupabase },
});

async function getAccessToken(canal: string, forcarRenovacao = false): Promise<string | null> {
  const { data: integ, error } = await supabase.from('integracoes_ml').select('*').eq('canal', canal).maybeSingle();
  if (error || !integ) return null;
  if (!forcarRenovacao && Date.now() < new Date(integ.expires_at).getTime() - 60000) return integ.access_token;
  const resp = await fetch('https://api.mercadolibre.com/oauth/token', {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: Deno.env.get('ML_CLIENT_ID')!,
      client_secret: Deno.env.get('ML_CLIENT_SECRET')!,
      refresh_token: integ.refresh_token,
    }),
  });
  const data = await resp.json();
  if (!resp.ok) { console.error('Erro ao renovar token ML:', data); return null; }
  await supabase.from('integracoes_ml').update({
    access_token: data.access_token, refresh_token: data.refresh_token,
    expires_at: new Date(Date.now() + data.expires_in * 1000).toISOString(), updated_at: new Date().toISOString(),
  }).eq('canal', canal);
  return data.access_token;
}

// formato aceito pelo filtro de data do ML: 2026-10-29T12:00:00.000-00:00
const dataML = (d: Date) => d.toISOString().replace('Z', '-00:00');

const POR_PAGINA = 50;
const MAX_PAGINAS = 6;          // até 300 pedidos atualizados por conta na janela

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  const resposta = (obj: unknown, status = 200) => new Response(JSON.stringify(obj, null, 2), {
    status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json; charset=utf-8' },
  });

  const url = new URL(req.url);
  const horas = Math.min(Math.max(Number(url.searchParams.get('horas')) || 3, 1), 72);
  const desde = new Date(Date.now() - horas * 3600 * 1000);
  // ?simular=1 → só lista o que seria reenviado, sem chamar o webhook
  const simular = url.searchParams.get('simular') === '1';

  const { data: contas, error: errContas } = await supabase.from('integracoes_ml').select('canal, ml_user_id');
  if (errContas) return resposta({ erro: errContas.message }, 500);

  const resumo: Record<string, any> = { janela_horas: horas, simulacao: simular, contas: {} };

  for (const conta of contas || []) {
    const canal = conta.canal as string;
    const r: any = { vistos: 0, importados: 0, cancelamentos: 0, erros: [] as string[] };
    resumo.contas[canal] = r;
    if (!conta.ml_user_id) { r.erros.push('conta sem ml_user_id'); continue; }

    let token = await getAccessToken(canal);
    if (!token) { r.erros.push('sem token'); continue; }

    // 1) pedidos atualizados na janela
    const pedidosML: { id: string; status: string }[] = [];
    for (let pagina = 0; pagina < MAX_PAGINAS; pagina++) {
      const busca = `https://api.mercadolibre.com/orders/search?seller=${conta.ml_user_id}` +
        `&order.date_last_updated.from=${encodeURIComponent(dataML(desde))}` +
        `&sort=date_desc&limit=${POR_PAGINA}&offset=${pagina * POR_PAGINA}`;
      let resp = await fetch(busca, { headers: { Authorization: `Bearer ${token}` } });
      if (resp.status === 401) {
        token = await getAccessToken(canal, true);
        if (!token) { r.erros.push('token recusado'); break; }
        resp = await fetch(busca, { headers: { Authorization: `Bearer ${token}` } });
      }
      if (!resp.ok) { r.erros.push(`busca HTTP ${resp.status}`); break; }
      const json = await resp.json();
      const lote = (json.results || []).map((o: any) => ({ id: String(o.id), status: String(o.status || '') }));
      pedidosML.push(...lote);
      const total = Number(json.paging?.total || 0);
      if (lote.length < POR_PAGINA || (pagina + 1) * POR_PAGINA >= total) break;
    }
    r.vistos = pedidosML.length;
    if (!pedidosML.length) continue;

    // 2) o que o ERP já tem
    const { data: noErp, error: errErp } = await supabase.from('pedidos_venda')
      .select('ml_order_id, status').in('ml_order_id', pedidosML.map((p) => p.id));
    if (errErp) { r.erros.push('leitura ERP: ' + errErp.message); continue; }
    const statusErp = new Map((noErp || []).map((p: any) => [String(p.ml_order_id), p.status]));

    // 3) reenvia ao ml-webhook só o necessário
    for (const p of pedidosML) {
      const erp = statusErp.get(p.id);
      const faltando = erp === undefined;
      const cancelarNoErp = p.status === 'cancelled' && erp === 'confirmado';
      if (!faltando && !cancelarNoErp) continue;
      if (simular) {
        (r.simulados ||= []).push(`${p.id} (${faltando ? 'falta no ERP' : 'cancelado no ML'})`);
        continue;
      }
      try {
        const w = await fetch(`${SUPABASE_URL}/functions/v1/ml-webhook`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ topic: 'orders_v2', resource: `/orders/${p.id}`, user_id: conta.ml_user_id }),
        });
        if (!w.ok) { r.erros.push(`webhook HTTP ${w.status} no pedido ${p.id}`); continue; }
        if (faltando) r.importados++; else r.cancelamentos++;
      } catch (e) {
        r.erros.push(`pedido ${p.id}: ${String(e)}`);
      }
    }
    if (r.importados || r.cancelamentos) {
      console.log(`ml-sync-pedidos ${canal}: ${r.importados} importado(s), ${r.cancelamentos} cancelamento(s) que o webhook tinha perdido`);
    }
  }

  return resposta(resumo);
});
