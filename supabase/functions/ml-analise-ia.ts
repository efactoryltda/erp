// ============================================================
// ERP E-Factory — Edge Function: ml-analise-ia
// O "Gestor de Contas (IA)": junta um retrato dos 6 domínios de dado das
// 3 contas Mercado Livre (vendas, estoque, anúncios, Ads, promoções e
// perguntas) pro período pedido (diária/semanal/mensal), manda pro
// Claude com instrução de atuar como gestor de contas especialista, e
// guarda a análise gerada em `ml_analises`.
//
// Body esperado (POST): { "tipo": "diaria" | "semanal" | "mensal" }
// Opcional, pra regerar um período passado:
//   { "tipo": "semanal", "periodo_inicio": "2026-09-14", "periodo_fim": "2026-09-20" }
// (se vier só um dos dois, é erro; sem nenhum, usa o cálculo automático abaixo)
//
// Períodos (aproximação por data UTC, mesmo padrão simplificado já usado
// nas outras sincronizações diárias — não é um corte fino de fuso):
//   diaria  -> ontem
//   semanal -> últimos 7 dias terminando ontem
//   mensal  -> últimos 30 dias terminando ontem
// ============================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

// ------------------------------------------------------------
// Proteção contra o erro intermitente do Supabase "JWT issued at future"
// (PGRST303). Esse JWT é gerado pelo próprio gateway do Supabase a partir da
// chave de serviço; quando o relógio dele fica alguns segundos à frente do
// banco, a consulta é recusada. Foi isso que deixou as análises de 10/09,
// 15/09 e a semanal 14–20/09 sem Ads/estoque. Não dá pra corrigir o iat do
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

function toISODate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function calcularPeriodo(tipo: string): { inicio: string; fim: string } {
  const hoje = new Date();
  const ontem = new Date(hoje);
  ontem.setUTCDate(ontem.getUTCDate() - 1);

  const inicio = new Date(ontem);
  if (tipo === 'semanal') inicio.setUTCDate(inicio.getUTCDate() - 6);
  else if (tipo === 'mensal') inicio.setUTCDate(inicio.getUTCDate() - 29);
  // 'diaria': inicio === ontem

  return { inicio: toISODate(inicio), fim: toISODate(ontem) };
}

async function buscarVendas(inicioISO: string, fimExclusivoISO: string) {
  const { data, error } = await supabase
    .from('pedidos_venda')
    .select('canal, valor_total, data_pedido, pedido_itens(quantidade, sku_ml_item, produto_id, produtos(nome, sku_interno))')
    .eq('status', 'confirmado')
    .gte('data_pedido', inicioISO)
    .lt('data_pedido', fimExclusivoISO);
  if (error) return { erro: error.message };

  let faturamento_total = 0;
  const por_canal: Record<string, number> = {};
  const por_produto: Record<string, { produto: string; sku: string; quantidade: number }> = {};

  for (const pedido of data || []) {
    const valor = Number(pedido.valor_total) || 0;
    faturamento_total += valor;
    por_canal[pedido.canal] = (por_canal[pedido.canal] || 0) + valor;

    for (const item of pedido.pedido_itens || []) {
      const chave = item.produto_id || `sku:${item.sku_ml_item || '?'}`;
      const nome = item.produtos?.nome || `⚠️ SKU não identificado (${item.sku_ml_item || '?'})`;
      const sku = item.produtos?.sku_interno || item.sku_ml_item || '?';
      if (!por_produto[chave]) por_produto[chave] = { produto: nome, sku, quantidade: 0 };
      por_produto[chave].quantidade += Number(item.quantidade) || 0;
    }
  }

  return {
    total_pedidos: (data || []).length,
    faturamento_total: +faturamento_total.toFixed(2),
    faturamento_por_canal: por_canal,
    quantidade_vendida_por_produto: Object.values(por_produto).sort((a, b) => b.quantidade - a.quantidade),
  };
}

async function buscarEstoque() {
  const { data: produtos, error: e1 } = await supabase
    .from('produtos').select('id, nome, sku_interno, estoque_minimo').eq('ativo', true);
  if (e1) return { erro: e1.message };

  const { data: saldos, error: e2 } = await supabase.from('estoque_saldos').select('produto_id, local, quantidade');
  if (e2) return { erro: e2.message };

  const porProduto: Record<string, { full: number; fisico_flex_deposito: number; total: number }> = {};
  for (const s of saldos || []) {
    if (!porProduto[s.produto_id]) porProduto[s.produto_id] = { full: 0, fisico_flex_deposito: 0, total: 0 };
    const qtd = Number(s.quantidade) || 0;
    if (s.local === 'fisico') porProduto[s.produto_id].fisico_flex_deposito += qtd;
    else if (String(s.local).startsWith('full_')) porProduto[s.produto_id].full += qtd;
    porProduto[s.produto_id].total += qtd;
  }

  const risco_de_ruptura: any[] = [];
  for (const p of produtos || []) {
    const saldo = porProduto[p.id] || { full: 0, fisico_flex_deposito: 0, total: 0 };
    const minimo = Number(p.estoque_minimo) || 0;
    if (saldo.total < minimo) {
      risco_de_ruptura.push({ produto: p.nome, sku: p.sku_interno, ...saldo, minimo });
    }
  }

  return { risco_de_ruptura };
}

async function buscarAds(inicio: string, fim: string) {
  const { data, error } = await supabase.from('ml_ads_metricas_diarias').select('*').gte('data', inicio).lte('data', fim);
  if (error) return { erro: error.message };

  const porCampanha: Record<string, any> = {};
  for (const m of data || []) {
    const chave = `${m.canal}:${m.campaign_id}`;
    if (!porCampanha[chave]) {
      porCampanha[chave] = { canal: m.canal, campanha: m.campaign_name || m.campaign_id, impressoes: 0, cliques: 0, custo: 0, vendas_totais: 0 };
    }
    porCampanha[chave].impressoes += Number(m.impressoes) || 0;
    porCampanha[chave].cliques += Number(m.cliques) || 0;
    porCampanha[chave].custo += Number(m.custo) || 0;
    porCampanha[chave].vendas_totais += Number(m.vendas_totais) || 0;
  }

  const campanhas = Object.values(porCampanha).map((c: any) => ({
    ...c,
    custo: +c.custo.toFixed(2),
    acos_percentual: c.vendas_totais > 0 ? +((c.custo / c.vendas_totais) * 100).toFixed(2) : null,
  }));

  return { campanhas };
}

async function buscarPromocoes(fimPeriodoISO: string) {
  const { data, error } = await supabase.from('ml_promocoes_ativas').select('*, produtos(nome, sku_interno)');
  if (error) return { erro: error.message };

  const referencia = new Date(fimPeriodoISO + 'T23:59:59Z').getTime();
  const tresDiasMs = 3 * 24 * 60 * 60 * 1000;

  const ativas = (data || []).map((p: any) => {
    const fimPromo = p.data_fim ? new Date(p.data_fim).getTime() : null;
    return {
      canal: p.canal,
      produto: p.produtos?.nome || p.item_id,
      tipo: p.tipo,
      nome: p.nome,
      preco_promocional: p.preco_promocional,
      preco_original: p.preco_original,
      data_fim: p.data_fim,
      vencendo_em_breve: fimPromo !== null && fimPromo - referencia <= tresDiasMs,
    };
  });

  return { ativas };
}

async function buscarPerguntas() {
  const { data, error } = await supabase.from('ml_perguntas_abertas').select('*, produtos(nome, sku_interno)');
  if (error) return { erro: error.message };

  const agora = Date.now();
  const em_aberto = (data || []).map((p: any) => ({
    canal: p.canal,
    produto: p.produtos?.nome || p.item_id,
    texto: p.texto,
    horas_em_aberto: p.data_pergunta ? Math.round((agora - new Date(p.data_pergunta).getTime()) / 3600000) : null,
  }));

  return { em_aberto };
}

async function buscarAnuncios(inicio: string, fim: string) {
  const { data, error } = await supabase
    .from('ml_anuncios_metricas')
    .select('*, produtos(nome, sku_interno)')
    .gte('data', inicio)
    .lte('data', fim)
    .order('data', { ascending: true });
  if (error) return { erro: error.message };

  const porItem: Record<string, any> = {};
  for (const m of data || []) {
    const chave = `${m.canal}:${m.item_id}`;
    if (!porItem[chave]) porItem[chave] = { canal: m.canal, produto: m.produtos?.nome || m.item_id, visitas_periodo: 0, ultima: null };
    porItem[chave].visitas_periodo += Number(m.visitas) || 0;
    porItem[chave].ultima = m; // fica com a mais recente (dados vêm ordenados por data crescente)
  }

  const anuncios = Object.values(porItem).map((it: any) => ({
    canal: it.canal,
    produto: it.produto,
    visitas_periodo: it.visitas_periodo,
    qualidade_score: it.ultima?.quality_score ?? null,
    qualidade_nivel: it.ultima?.quality_level ?? null,
    qualidade_pendencias: it.ultima?.quality_pendencias ?? null,
    avaliacao_media: it.ultima?.rating_average ?? null,
    total_avaliacoes: it.ultima?.total_avaliacoes ?? null,
    eh_catalogo: it.ultima?.eh_catalogo ?? null,
    status_concorrencia: it.ultima?.status_concorrencia ?? null,
  }));

  return { anuncios };
}

const SYSTEM_PROMPT = `Você é um gestor de contas sênior, especialista em Mercado Livre, Mercado Ads e operação de e-commerce, contratado pela E-Factory Group (fabricante de caixas de papelão, etiquetas térmicas e sacos de envio, Ribeirão Preto/SP) para analisar a operação das 3 contas Mercado Livre da empresa.

Você recebe um retrato de dados de um período (diário, semanal ou mensal) e deve escrever uma análise objetiva e acionável em português do Brasil, em texto corrido (sem tabelas), com esta estrutura:

1. Resumo do período (2-3 frases com o que mais importa)
2. Vendas (o que subiu/caiu, produtos destaque, comparação entre as 3 contas quando relevante)
3. Estoque (risco de ruptura, considerando o saldo Full e o físico/Flex/Depósito juntos — sem separar os dois)
4. Anúncios (visitas, uma leitura informal de conversão cruzando visitas com vendas do mesmo produto, qualidade da publicação e o que falta melhorar, avaliações dos compradores, e concorrência de preço só para os anúncios de Catálogo)
5. Ads (campanhas com bom ou mau desempenho, ACOS, oportunidades)
6. Promoções (ativas, vencendo em breve, oportunidades)
7. Perguntas (atenção especial a perguntas em aberto há muito tempo)
8. Ações recomendadas (lista curta, 3 a 5 itens, concretos e priorizados)

Regras importantes:
- Seja direto e prático, como um consultor experiente falando com o dono do negócio — não um relatório burocrático.
- Se um tópico não tiver nada relevante no período, diga isso em uma frase curta e siga em frente — não force conteúdo.
- Produtos da linha "Little Tree" estão descontinuados — ignore-os se aparecerem nos dados.
- Nunca invente números que não estejam nos dados fornecidos.`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  try {
    const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
    if (!apiKey) {
      return new Response(JSON.stringify({ ok: false, erro: 'ANTHROPIC_API_KEY não configurada nos Secrets do Supabase.' }), {
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const body = await req.json().catch(() => ({}));
    const tipo = body.tipo;
    if (!['diaria', 'semanal', 'mensal'].includes(tipo)) {
      return new Response(JSON.stringify({ ok: false, erro: 'Informe "tipo": "diaria", "semanal" ou "mensal".' }), {
        status: 400,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    let inicio: string;
    let fim: string;
    const temInicio = body.periodo_inicio !== undefined;
    const temFim = body.periodo_fim !== undefined;
    if (temInicio || temFim) {
      const formatoData = /^\d{4}-\d{2}-\d{2}$/;
      const valida = (v: unknown) =>
        typeof v === 'string' && formatoData.test(v) && !isNaN(new Date(v + 'T00:00:00Z').getTime());
      if (!valida(body.periodo_inicio) || !valida(body.periodo_fim) || body.periodo_inicio > body.periodo_fim) {
        return new Response(JSON.stringify({ ok: false, erro: 'Para período manual, informe "periodo_inicio" e "periodo_fim" no formato AAAA-MM-DD, com início <= fim.' }), {
          status: 400,
          headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
        });
      }
      inicio = body.periodo_inicio;
      fim = body.periodo_fim;
    } else {
      ({ inicio, fim } = calcularPeriodo(tipo));
    }
    const inicioISO = `${inicio}T00:00:00-03:00`;
    const fimExclusivoISO = `${toISODate(new Date(new Date(fim + 'T00:00:00Z').getTime() + 86400000))}T00:00:00-03:00`;

    const [vendas, estoque, ads, promocoes, perguntas, anuncios] = await Promise.all([
      buscarVendas(inicioISO, fimExclusivoISO),
      buscarEstoque(),
      buscarAds(inicio, fim),
      buscarPromocoes(fim),
      buscarPerguntas(),
      buscarAnuncios(inicio, fim),
    ]);

    const dadosPeriodo = { tipo, periodo_inicio: inicio, periodo_fim: fim, vendas, estoque, anuncios, ads, promocoes, perguntas };

    const userMessage =
      `Retrato de dados do período "${tipo}" (${inicio} a ${fim}):\n\n` +
      '```json\n' + JSON.stringify(dadosPeriodo, null, 2) + '\n```\n\n' +
      'Gere a análise conforme as instruções.';

    const respIA = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: 'claude-sonnet-5',
        max_tokens: 2000,
        system: SYSTEM_PROMPT,
        messages: [{ role: 'user', content: userMessage }],
      }),
    });

    const dadosIA = await respIA.json();
    if (!respIA.ok) {
      return new Response(JSON.stringify({ ok: false, erro: `Anthropic API retornou ${respIA.status}: ${dadosIA.error?.message || JSON.stringify(dadosIA)}` }), {
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const conteudo = (dadosIA.content || []).map((b: any) => b.text || '').join('\n').trim();
    if (!conteudo) {
      return new Response(JSON.stringify({ ok: false, erro: 'A IA não retornou texto de análise.' }), {
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const { error: erroGravar } = await supabase.from('ml_analises').upsert(
      {
        tipo,
        periodo_inicio: inicio,
        periodo_fim: fim,
        conteudo,
        dados_brutos: dadosPeriodo,
        gerado_em: new Date().toISOString(),
      },
      { onConflict: 'tipo,periodo_inicio,periodo_fim' }
    );

    if (erroGravar) {
      return new Response(JSON.stringify({ ok: false, erro: `Análise gerada mas falhou ao salvar: ${erroGravar.message}` }), {
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ ok: true, tipo, periodo_inicio: inicio, periodo_fim: fim, conteudo }), {
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, erro: String(e) }), {
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
});