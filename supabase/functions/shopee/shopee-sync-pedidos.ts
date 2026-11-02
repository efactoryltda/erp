// ============================================================
// ERP E-Factory — Edge Function: shopee-sync-pedidos  (Lote 10c)
// Rede de segurança do aviso (igual ao ml-sync-pedidos): a cada 15 min
// lê os pedidos atualizados nas últimas horas e aplica no ERP o que
// faltar (pedido novo, mudança de status, cancelamento). Também mantém
// o acesso renovado (o token da Shopee vale só 4h).
// ?horas=N (padrão 3, máx 360 = 15 dias) · ?simular=1 (não grava nada)
// ============================================================
import { aplicarPedido, detalharPedidos, json, listarAtualizados, obterConexao } from './shopee.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return json({ ok: true });
  const url = new URL(req.url);
  const horas = Math.min(Math.max(Number(url.searchParams.get('horas')) || 3, 1), 360);
  const simular = url.searchParams.get('simular') === '1';
  const resumo: any = { janela_horas: horas, simulacao: simular, vistos: 0, resultado: {}, erros: [] as string[] };
  try {
    const con = await obterConexao();
    if (!con) return json({ ...resumo, aviso: 'Nenhuma loja Shopee conectada' });
    resumo.ambiente = con.ambiente;
    const ate = Math.floor(Date.now() / 1000);
    const sns = await listarAtualizados(con, ate - horas * 3600, ate);
    resumo.vistos = sns.length;
    if (!sns.length) return json(resumo);
    for (const o of await detalharPedidos(con, sns)) {
      try {
        const r = await aplicarPedido(con, o, simular);
        const chave = r.split(' (')[0];
        resumo.resultado[chave] = (resumo.resultado[chave] || 0) + 1;
        if (simular || chave !== 'sem_mudanca') (resumo.detalhes ||= []).push(`${o.order_sn}: ${r}`);
      } catch (e) {
        if (resumo.erros.length < 20) resumo.erros.push(`${o.order_sn}: ${(e as Error).message}`);
      }
    }
  } catch (e) {
    resumo.erros.push((e as Error).message);
  }
  return json(resumo);
});
