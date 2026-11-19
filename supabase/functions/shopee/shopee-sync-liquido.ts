// ============================================================
// ERP E-Factory — Edge Function: shopee-sync-liquido  (Lote 16 — fase 2 Shopee)
// Lê o repasse ("escrow") de cada venda na Shopee: comissão, taxa de serviço,
// taxa de transação, frete, descontos e o valor líquido que a Shopee paga.
// Grava (via RPC registrar_liquido_shopee):
//   • colunas de líquido do pedido (as mesmas usadas pelo ML na tela de Vendas)
//   • 1 lançamento em Contas a receber (origem 'shopee') por pedido
// Data de liberação = quando a Shopee liberou o dinheiro (get_escrow_list);
// enquanto não libera, o lançamento fica "aguardando".
// ?ver=<order_sn>   mostra o escrow cru (não grava)
// ?simular=1        calcula e devolve, sem gravar
// ?limite=N         pedidos por rodada (padrão 40)
// ============================================================
import { getLoja, json, obterConexao, supabase, type Conexao } from './shopee.ts';

const r2 = (n: number) => (Math.round(n * 100) / 100) || 0;
const num = (v: unknown) => Number(v ?? 0) || 0;

async function escrow(con: Conexao, sn: string) {
  return await getLoja(con, '/api/v2/payment/get_escrow_detail', { order_sn: sn });
}

// order_sn → data/hora em que a Shopee liberou o repasse (últimos ~60 dias)
async function liberacoes(con: Conexao) {
  const mapa = new Map<string, number>();
  const agora = Math.floor(Date.now() / 1000);
  for (let janela = 0; janela < 4; janela++) {            // 4 janelas de 15 dias
    const ate = agora - janela * 15 * 86400;
    const de = ate - 15 * 86400;
    for (let pagina = 1; pagina <= 20; pagina++) {
      const r = await getLoja(con, '/api/v2/payment/get_escrow_list', {
        release_time_from: String(de), release_time_to: String(ate), page_size: '100', page_no: String(pagina),
      });
      if (r.error) throw new Error(`get_escrow_list: ${r.error} ${r.message || ''}`);
      for (const e of r.response?.escrow_list || []) mapa.set(String(e.order_sn), Number(e.escrow_release_time));
      if (!r.response?.more) break;
    }
  }
  return mapa;
}

// Converte o escrow da Shopee nos campos do ERP (mesma convenção do ML):
//   líquido = bruto − tarifa − frete − taxas − outros − reembolsado
function montar(ped: { valor_total: number; status: string }, oi: any, liberadoEm: number | null) {
  const bruto = r2(num(ped.valor_total));
  const liquido = r2(num(oi.escrow_amount_after_adjustment ?? oi.escrow_amount));
  const tarifa = r2(num(oi.commission_fee) + num(oi.service_fee));                 // valores cheios (bate com o repasse)
  // taxas do vendedor (credit_card_transaction_fee é paga pelo COMPRADOR — fica fora)
  const taxas = r2(num(oi.shipping_seller_protection_fee_amount) + num(oi.seller_transaction_fee)
    + num(oi.order_ams_commission_fee) + num(oi.campaign_fee) + num(oi.fbs_fee) + num(oi.seller_order_processing_fee));
  const reembolsado = r2(Math.abs(num(oi.seller_return_refund)));
  // Frete: final_shipping_fee vem negativo mesmo quando o comprador/Shopee pagou o frete,
  // então só conta como frete do vendedor a parte que de fato saiu do repasse.
  const resto = r2(bruto - tarifa - taxas - reembolsado - liquido);
  const freteMax = r2(Math.max(0, -num(oi.final_shipping_fee)) + num(oi.reverse_shipping_fee)
    + num(oi.final_return_to_seller_shipping_fee));
  const frete = r2(Math.min(Math.max(resto, 0), freteMax));
  const outros = r2(resto - frete);                                                // vouchers do vendedor, ajustes etc.
  const estornado = ped.status === 'cancelado' || (reembolsado > 0 && liquido <= 0);
  return {
    bruto, tarifa, frete, taxas, outros, reembolsado, liquido, estornado,
    liquido_status: estornado ? 'estornado' : reembolsado > 0 ? 'reembolso_parcial' : 'ok',
    liberado_em: liberadoEm ? new Date(liberadoEm * 1000).toISOString() : null,
    resumo: {
      fonte: 'shopee_escrow', preco_venda: num(oi.order_selling_price), comissao: num(oi.commission_fee),
      taxa_servico: num(oi.service_fee), protecao_frete: num(oi.shipping_seller_protection_fee_amount),
      frete_final: num(oi.final_shipping_fee), voucher_vendedor: num(oi.voucher_from_seller),
      reembolso: num(oi.seller_return_refund), ajustes: num(oi.total_adjustment_amount),
      repasse: liquido, pagamento: oi.buyer_payment_method ?? null,
    },
  };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return json({ ok: true });
  const url = new URL(req.url);
  const ver = url.searchParams.get('ver');
  const simular = url.searchParams.get('simular') === '1';
  const limite = Math.min(200, Math.max(1, Number(url.searchParams.get('limite') || 40) || 40));
  try {
    const con = await obterConexao();
    if (!con) return json({ aviso: 'Nenhuma loja Shopee conectada' });
    if (ver) {
      const [e, lib] = await Promise.all([escrow(con, ver), liberacoes(con).catch((x) => String(x))]);
      return json({ escrow: e, liberado_em: typeof lib === 'string' ? lib : lib.get(ver) ?? null });
    }
    if (con.ambiente !== 'producao') return json({ aviso: 'Loja conectada é sandbox — nada a fazer' });

    const { data: fila, error } = await supabase.rpc('fila_liquido_shopee', { p_limite: limite });
    if (error) throw new Error('fila: ' + error.message);
    if (!fila?.length) return json({ ok: true, processados: 0 });

    const lib = await liberacoes(con);
    const res = { ok: true, simular, processados: 0, recebidos: 0, aguardando: 0, estornados: 0, erros: [] as string[],
      bruto: 0, liquido: 0, itens: [] as any[] };
    for (const p of fila as any[]) {
      try {
        const e = await escrow(con, p.order_sn);
        const oi = e?.response?.order_income;
        if (e?.error || !oi) { res.erros.push(`${p.order_sn}: ${e?.error || 'sem order_income'} ${e?.message || ''}`.trim()); continue; }
        const d = montar(p, oi, lib.get(p.order_sn) ?? null);
        if (!simular) {
          const { error: er } = await supabase.rpc('registrar_liquido_shopee', { p_pedido_id: p.pedido_id, p_dados: d });
          if (er) { res.erros.push(`${p.order_sn}: ${er.message}`); continue; }
        }
        res.processados++;
        if (d.estornado) res.estornados++; else if (d.liberado_em) res.recebidos++; else res.aguardando++;
        if (!d.estornado) { res.bruto = r2(res.bruto + d.bruto); res.liquido = r2(res.liquido + d.liquido); }
        if (simular) res.itens.push({ sn: p.order_sn, st: p.shopee_status, ...d, resumo: undefined });
      } catch (x) {
        res.erros.push(`${p.order_sn}: ${(x as Error).message}`);
      }
    }
    return json(res);
  } catch (e) {
    return json({ erro: (e as Error).message }, 500);
  }
});
