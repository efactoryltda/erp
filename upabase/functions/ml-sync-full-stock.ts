// ============================================================
// ERP E-Factory — Edge Function: ml-sync-full-stock
// Consulta o estoque Full real de cada anúncio conectado e corrige
// o saldo no ERP pra bater com o que está de verdade no Mercado Livre.
// ============================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
);

const FULL_LOCAL_POR_CANAL: Record<string, string> = {
  ml_conta1: 'full_conta1',
  ml_conta2: 'full_conta2',
  ml_conta3: 'full_conta3',
};

async function getAccessToken(canal: string): Promise<string | null> {
  const { data: integ } = await supabase.from('integracoes_ml').select('*').eq('canal', canal).maybeSingle();
  if (!integ) return null;

  const expiraEm = new Date(integ.expires_at).getTime();
  if (Date.now() < expiraEm - 60000) {
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

// Descobre a quantidade em Full de um anúncio, seja ele do tipo novo (MLBU...)
// ou do tipo clássico (MLB...), que usam APIs diferentes no Mercado Livre.
async function buscarQuantidadeFull(itemId: string, token: string): Promise<number | null> {
  const ehFormatoNovo = /^ML[A-Z]U/.test(itemId);

  if (ehFormatoNovo) {
    const resp = await fetch(`https://api.mercadolibre.com/user-products/${itemId}/stock`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const dados = await resp.json();
    if (!resp.ok) throw new Error(`ML retornou ${resp.status} em user-products/stock`);
    const local = (dados.locations || []).find((l: any) => l.type === 'meli_facility');
    return local ? Number(local.quantity) : 0;
  }

  // formato clássico: primeiro descobre o inventory_id do anúncio
  const respItem = await fetch(`https://api.mercadolibre.com/items/${itemId}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const item = await respItem.json();
  if (!respItem.ok) throw new Error(`ML retornou ${respItem.status} em /items`);

  if (!item.inventory_id) {
    // anúncio não está configurado pra fulfillment
    return 0;
  }

  const respEstoque = await fetch(`https://api.mercadolibre.com/inventories/${item.inventory_id}/stock/fulfillment`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const estoque = await respEstoque.json();
  if (!respEstoque.ok) throw new Error(`ML retornou ${respEstoque.status} em /inventories/stock/fulfillment`);

  // usamos available_quantity (o que está de fato disponível pra vender) —
  // não o "total", que inclui unidades danificadas/perdidas/em processo.
  return Number(estoque.available_quantity || 0);
}

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  const resultado: any[] = [];

  const { data: anuncios, error } = await supabase.from('produto_anuncios_ml').select('produto_id, canal, item_id');
  if (error) {
    return new Response(JSON.stringify({ erro: error.message }), { status: 500, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
  }

  for (const anuncio of anuncios || []) {
    const local = FULL_LOCAL_POR_CANAL[anuncio.canal];
    if (!local) continue;

    const token = await getAccessToken(anuncio.canal);
    if (!token) {
      resultado.push({ produto_id: anuncio.produto_id, canal: anuncio.canal, erro: 'conta não conectada' });
      continue;
    }

    try {
      const quantidadeReal = await buscarQuantidadeFull(anuncio.item_id, token);

      const { data: saldoAtual } = await supabase
        .from('estoque_saldos')
        .select('*')
        .eq('produto_id', anuncio.produto_id)
        .eq('local', local)
        .maybeSingle();

      const quantidadeAtual = saldoAtual ? Number(saldoAtual.quantidade) : 0;
      const diferenca = (quantidadeReal || 0) - quantidadeAtual;

      if (diferenca !== 0) {
        if (saldoAtual) {
          await supabase.from('estoque_saldos').update({ quantidade: quantidadeReal, updated_at: new Date().toISOString() }).eq('id', saldoAtual.id);
        } else {
          await supabase.from('estoque_saldos').insert({ produto_id: anuncio.produto_id, local, quantidade: quantidadeReal });
        }

        await supabase.from('movimentacoes_estoque').insert({
          produto_id: anuncio.produto_id,
          local,
          tipo_movimento: 'ajuste',
          quantidade: diferenca,
          referencia_tipo: 'sincronizacao_full',
          observacao: `Sincronizado com o Mercado Livre (era ${quantidadeAtual}, ficou ${quantidadeReal})`,
        });
      }

      resultado.push({ produto_id: anuncio.produto_id, canal: anuncio.canal, quantidade_anterior: quantidadeAtual, quantidade_atual_ml: quantidadeReal, ajustado: diferenca !== 0 });
    } catch (e) {
      resultado.push({ produto_id: anuncio.produto_id, canal: anuncio.canal, erro: String(e) });
    }
  }

  return new Response(JSON.stringify(resultado, null, 2), {
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json; charset=utf-8' },
  });
});
