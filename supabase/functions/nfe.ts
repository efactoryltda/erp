// ============================================================
// ERP E-Factory — Edge Function: nfe  (Lote 9 — Nota Fiscal)
//
// Único ponto que GRAVA notas fiscais. O navegador só lê.
// Chamada pelo ERP (usuário logado) com POST { acao, ... }:
//   { acao: 'emitir',           pedido_id }
//   { acao: 'consultar',        nota_id }               (atualiza status)
//   { acao: 'cancelar',         nota_id, justificativa } (15 a 255 letras)
//   { acao: 'email',            nota_id, email? }
//   { acao: 'limpar_simulacao' }                         (só notas de simulação)
//
// Segurança: "Verify JWT" fica DESLIGADO no painel (padrão do projeto),
// mas esta função confere o login de verdade (auth.getUser) e recusa
// quem não estiver logado no ERP.
//
// Plataforma emissora ("provedor"): peça trocável. Hoje só existe a
// SIMULAÇÃO (não fala com a SEFAZ, gera XML marcado "SEM VALOR FISCAL").
// Quando a plataforma real for escolhida, entra um novo provedor aqui
// (mesmas 4 operações) e nada mais muda no ERP.
// ============================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

// Proteção contra o erro intermitente "JWT issued at future" (PGRST303) —
// mesmo padrão das outras funções do projeto.
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
  auth: { persistSession: false },
});

const BUCKET = 'notas-fiscais';
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
function resposta(corpo: unknown, status = 200) {
  return new Response(JSON.stringify(corpo), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

// ------------------------------------------------------------
// Tipos e utilidades
// ------------------------------------------------------------
type Nota = Record<string, any>;
type ResultadoEmissao = {
  status: 'autorizada' | 'rejeitada' | 'processando' | 'erro';
  codigo_status?: string; motivo?: string; chave?: string; protocolo?: string;
  data_autorizacao?: string; provedor_ref?: string; xml?: string; pdf?: Uint8Array;
};
type ResultadoCancelamento = {
  ok: boolean; status: 'cancelada' | 'cancelando' | 'autorizada'; motivo?: string; protocolo?: string; xml?: string;
};
interface Provedor {
  emitir(nota: Nota): Promise<ResultadoEmissao>;
  consultar(nota: Nota): Promise<ResultadoEmissao>;
  cancelar(nota: Nota, justificativa: string): Promise<ResultadoCancelamento>;
  enviarEmail(nota: Nota, email: string): Promise<{ ok: boolean; mensagem: string }>;
}

function xmlEsc(v: unknown): string {
  return String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' }[c]!));
}
const n2 = (v: unknown) => Number(v ?? 0).toFixed(2);
const n4 = (v: unknown) => Number(v ?? 0).toFixed(4);
const soDigitos = (v: unknown) => String(v ?? '').replace(/\D/g, '');

// data/hora de Brasília no formato da NF-e (AAAA-MM-DDThh:mm:ss-03:00)
function agoraBrasilia(): { iso: string; aamm: string; anoMes: string } {
  const f = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Sao_Paulo', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
  });
  const p = Object.fromEntries(f.formatToParts(new Date()).map((x) => [x.type, x.value]));
  return {
    iso: `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:${p.second}-03:00`,
    aamm: `${p.year.slice(2)}${p.month}`,
    anoMes: `${p.year}-${p.month}`,
  };
}

// Chave de acesso (44 dígitos) com dígito verificador módulo 11 — layout oficial.
function montarChave(cUF: string, aamm: string, cnpj: string, modelo: number, serie: number, numero: number, tpEmis = 1): string {
  let cNF = '';
  do { cNF = String(Math.floor(Math.random() * 1e8)).padStart(8, '0'); } while (cNF === String(numero).padStart(8, '0').slice(-8));
  const base = cUF + aamm + cnpj.padStart(14, '0') + String(modelo).padStart(2, '0') + String(serie).padStart(3, '0')
    + String(numero).padStart(9, '0') + String(tpEmis) + cNF;
  if (base.length !== 43) throw new Error('Chave de acesso com tamanho errado: ' + base.length);
  let soma = 0, peso = 2;
  for (let i = base.length - 1; i >= 0; i--) { soma += Number(base[i]) * peso; peso = peso === 9 ? 2 : peso + 1; }
  const resto = soma % 11;
  const dv = resto < 2 ? 0 : 11 - resto;
  return base + dv;
}

const COD_UF: Record<string, string> = {
  RO: '11', AC: '12', AM: '13', RR: '14', PA: '15', AP: '16', TO: '17', MA: '21', PI: '22', CE: '23', RN: '24', PB: '25',
  PE: '26', AL: '27', SE: '28', BA: '29', MG: '31', ES: '32', RJ: '33', SP: '35', PR: '41', SC: '42', RS: '43', MS: '50',
  MT: '51', GO: '52', DF: '53',
};

// Forma de pagamento do ERP → código tPag da NF-e
function codigoPagamento(forma: string | null | undefined): string {
  const f = (forma || '').toLowerCase();
  if (f.includes('pix')) return '17';
  if (f.includes('dinheiro')) return '01';
  if (f.includes('crédito') || f.includes('credito')) return '03';
  if (f.includes('débito') || f.includes('debito')) return '04';
  if (f.includes('boleto')) return '15';
  if (f.includes('transfer')) return '18';
  return '99';
}

// ------------------------------------------------------------
// PROVEDOR: SIMULAÇÃO — não fala com a SEFAZ. Serve para testar o fluxo
// completo do ERP (status, numeração, XML, ZIP, cancelamento) sem custo.
// Tudo que ele gera é marcado "SIMULAÇÃO — SEM VALOR FISCAL".
// ------------------------------------------------------------
const provedorSimulacao: Provedor = {
  async emitir(nota) {
    const d = nota.dados;
    const t = agoraBrasilia();
    const chave = montarChave(COD_UF[d.emitente.uf] || '35', t.aamm, d.emitente.cnpj, 55, nota.serie, nota.numero);
    const protocolo = 'SIM' + Date.now();
    const itensXml = (d.itens as any[]).map((it) => `
      <det nItem="${it.n}">
        <prod>
          <cProd>${xmlEsc(it.codigo)}</cProd><cEAN>${xmlEsc(it.gtin || 'SEM GTIN')}</cEAN><xProd>${xmlEsc(it.descricao)}</xProd>
          <NCM>${xmlEsc(it.ncm)}</NCM>${it.cest ? `<CEST>${xmlEsc(it.cest)}</CEST>` : ''}<CFOP>${xmlEsc(it.cfop)}</CFOP>
          <uCom>${xmlEsc(it.unidade)}</uCom><qCom>${n4(it.quantidade)}</qCom><vUnCom>${Number(it.valor_unitario).toFixed(4)}</vUnCom>
          <vProd>${n2(it.valor_bruto)}</vProd><cEANTrib>${xmlEsc(it.gtin || 'SEM GTIN')}</cEANTrib><uTrib>${xmlEsc(it.unidade)}</uTrib>
          <qTrib>${n4(it.quantidade)}</qTrib><vUnTrib>${Number(it.valor_unitario).toFixed(4)}</vUnTrib>
          ${Number(it.valor_frete) > 0 ? `<vFrete>${n2(it.valor_frete)}</vFrete>` : ''}${Number(it.valor_desconto) > 0 ? `<vDesc>${n2(it.valor_desconto)}</vDesc>` : ''}
          <indTot>1</indTot>
        </prod>
        <imposto><ICMS><ICMSSN102><orig>${xmlEsc(it.origem)}</orig><CSOSN>${xmlEsc(it.csosn)}</CSOSN></ICMSSN102></ICMS></imposto>
      </det>`).join('');
    const dest = d.destinatario || {};
    const xml = `<?xml version="1.0" encoding="UTF-8"?>
<!-- SIMULAÇÃO DO ERP E-FACTORY — SEM VALOR FISCAL — NÃO FOI ENVIADA À SEFAZ -->
<nfeProc versao="4.00" xmlns="http://www.portalfiscal.inf.br/nfe">
  <NFe>
    <infNFe Id="NFe${chave}" versao="4.00">
      <ide>
        <cUF>${chave.slice(0, 2)}</cUF><cNF>${chave.slice(35, 43)}</cNF><natOp>${xmlEsc(d.natureza_operacao)}</natOp>
        <mod>55</mod><serie>${nota.serie}</serie><nNF>${nota.numero}</nNF><dhEmi>${t.iso}</dhEmi><tpNF>1</tpNF>
        <idDest>${d.destino}</idDest><cMunFG>${xmlEsc(d.emitente.codigo_municipio)}</cMunFG><tpImp>1</tpImp><tpEmis>1</tpEmis>
        <cDV>${chave.slice(43)}</cDV><tpAmb>2</tpAmb><finNFe>1</finNFe><indFinal>${d.consumidor_final}</indFinal>
        <indPres>${d.indicador_presenca}</indPres><procEmi>0</procEmi><verProc>ERP-EFACTORY-SIMULACAO</verProc>
      </ide>
      <emit>
        <CNPJ>${xmlEsc(d.emitente.cnpj)}</CNPJ><xNome>${xmlEsc(d.emitente.razao_social)}</xNome>
        <enderEmit><xLgr>${xmlEsc(d.emitente.logradouro)}</xLgr><nro>${xmlEsc(d.emitente.numero)}</nro><xBairro>${xmlEsc(d.emitente.bairro)}</xBairro>
          <cMun>${xmlEsc(d.emitente.codigo_municipio)}</cMun><xMun>${xmlEsc(d.emitente.municipio)}</xMun><UF>${xmlEsc(d.emitente.uf)}</UF><CEP>${xmlEsc(d.emitente.cep)}</CEP></enderEmit>
        <IE>${xmlEsc(soDigitos(d.emitente.ie))}</IE><CRT>${d.emitente.crt}</CRT>
      </emit>
      <dest>
        ${String(dest.documento || '').length === 14 ? `<CNPJ>${xmlEsc(dest.documento)}</CNPJ>` : `<CPF>${xmlEsc(dest.documento)}</CPF>`}
        <xNome>${xmlEsc(dest.nome)}</xNome>
        <enderDest><xLgr>${xmlEsc(dest.logradouro)}</xLgr><nro>${xmlEsc(dest.numero)}</nro><xBairro>${xmlEsc(dest.bairro)}</xBairro>
          <cMun>${xmlEsc(dest.codigo_municipio)}</cMun><xMun>${xmlEsc(dest.municipio)}</xMun><UF>${xmlEsc(dest.uf)}</UF><CEP>${xmlEsc(dest.cep)}</CEP></enderDest>
        <indIEDest>${dest.indicador_ie}</indIEDest>${dest.ie && dest.indicador_ie === 1 ? `<IE>${xmlEsc(dest.ie)}</IE>` : ''}
        ${dest.email ? `<email>${xmlEsc(dest.email)}</email>` : ''}
      </dest>${itensXml}
      <total><ICMSTot><vProd>${n2(d.totais.produtos)}</vProd><vFrete>${n2(d.totais.frete)}</vFrete><vDesc>${n2(d.totais.desconto)}</vDesc><vNF>${n2(d.totais.total)}</vNF></ICMSTot></total>
      <transp><modFrete>${d.transporte.modalidade_frete}</modFrete></transp>
      <pag><detPag><tPag>${codigoPagamento(d.pagamento?.forma)}</tPag><vPag>${n2(d.pagamento?.valor)}</vPag></detPag></pag>
      <infAdic><infCpl>${xmlEsc('SIMULACAO - SEM VALOR FISCAL. ' + (d.informacoes_complementares || ''))}</infCpl></infAdic>
    </infNFe>
  </NFe>
  <protNFe versao="4.00"><infProt><tpAmb>2</tpAmb><chNFe>${chave}</chNFe><dhRecbto>${t.iso}</dhRecbto><nProt>${protocolo}</nProt><cStat>100</cStat><xMotivo>SIMULACAO - Autorizado o uso da NF-e (sem valor fiscal)</xMotivo></infProt></protNFe>
</nfeProc>
`;
    return {
      status: 'autorizada', codigo_status: '100', motivo: 'SIMULAÇÃO — autorizada (sem valor fiscal, não foi à SEFAZ)',
      chave, protocolo, data_autorizacao: new Date().toISOString(), provedor_ref: 'sim-' + nota.id, xml,
    };
  },
  async consultar(nota) {
    return { status: nota.status, codigo_status: nota.codigo_status, motivo: nota.motivo, chave: nota.chave, protocolo: nota.protocolo };
  },
  async cancelar(nota, justificativa) {
    const t = agoraBrasilia();
    const protocolo = 'SIMCANC' + Date.now();
    const xml = `<?xml version="1.0" encoding="UTF-8"?>
<!-- SIMULAÇÃO DO ERP E-FACTORY — SEM VALOR FISCAL — NÃO FOI ENVIADA À SEFAZ -->
<procEventoNFe versao="1.00" xmlns="http://www.portalfiscal.inf.br/nfe">
  <evento versao="1.00"><infEvento Id="ID110111${nota.chave}01"><tpAmb>2</tpAmb><CNPJ>${xmlEsc(nota.cnpj_emitente)}</CNPJ>
    <chNFe>${nota.chave}</chNFe><dhEvento>${t.iso}</dhEvento><tpEvento>110111</tpEvento><nSeqEvento>1</nSeqEvento>
    <detEvento versao="1.00"><descEvento>Cancelamento</descEvento><nProt>${xmlEsc(nota.protocolo)}</nProt><xJust>${xmlEsc(justificativa)}</xJust></detEvento>
  </infEvento></evento>
  <retEvento versao="1.00"><infEvento><cStat>135</cStat><xMotivo>SIMULACAO - Evento registrado</xMotivo><nProt>${protocolo}</nProt></infEvento></retEvento>
</procEventoNFe>
`;
    return { ok: true, status: 'cancelada', motivo: 'SIMULAÇÃO — cancelamento registrado (sem valor fiscal)', protocolo, xml };
  },
  async enviarEmail(_nota, email) {
    return { ok: true, mensagem: `SIMULAÇÃO: nenhum e-mail foi enviado de verdade (seria para ${email}).` };
  },
};

function provedorPara(nome: string): Provedor {
  if (nome === 'simulacao') return provedorSimulacao;
  throw new Error(`A plataforma emissora "${nome}" ainda não foi integrada ao ERP. Volte a configuração para Simulação.`);
}

// ------------------------------------------------------------
// Gravação de arquivos e eventos
// ------------------------------------------------------------
async function salvarArquivo(caminho: string, conteudo: string | Uint8Array, tipo: string) {
  const { error } = await supabase.storage.from(BUCKET).upload(caminho, conteudo, { contentType: tipo, upsert: true });
  if (error) throw new Error('Não consegui guardar o arquivo ' + caminho + ': ' + error.message);
}
async function evento(nota_id: string | null, tipo: string, sucesso: boolean | null, mensagem: string, usuario: string, detalhe?: unknown) {
  await supabase.from('nfe_eventos').insert({ nota_id, tipo, sucesso, mensagem, usuario_email: usuario, detalhe: detalhe ?? null });
}
async function lerNota(id: string): Promise<Nota> {
  const { data, error } = await supabase.from('notas_fiscais').select('*').eq('id', id).maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error('Nota não encontrada.');
  return data;
}

// Aplica o resultado da plataforma na linha da nota (+ guarda XML/PDF)
async function aplicarResultado(nota: Nota, r: ResultadoEmissao, usuario: string) {
  const pasta = `${nota.ambiente}/${String(nota.data_emissao || new Date().toISOString()).slice(0, 7)}`;
  const upd: Record<string, unknown> = {
    status: r.status, codigo_status: r.codigo_status ?? null, motivo: r.motivo ?? null,
    updated_at: new Date().toISOString(),
  };
  if (r.chave) upd.chave = r.chave;
  if (r.protocolo) upd.protocolo = r.protocolo;
  if (r.data_autorizacao) upd.data_autorizacao = r.data_autorizacao;
  if (r.provedor_ref) upd.provedor_ref = r.provedor_ref;
  const nomeBase = r.chave || `${nota.serie}-${nota.numero}`;
  if (r.xml) { const c = `${pasta}/${nomeBase}-nfe.xml`; await salvarArquivo(c, r.xml, 'application/xml'); upd.xml_path = c; }
  if (r.pdf) { const c = `${pasta}/${nomeBase}-danfe.pdf`; await salvarArquivo(c, r.pdf, 'application/pdf'); upd.pdf_path = c; }
  const { error } = await supabase.from('notas_fiscais').update(upd).eq('id', nota.id);
  if (error) throw new Error('Não consegui gravar o retorno da nota: ' + error.message);
  await evento(nota.id, r.status, r.status === 'autorizada' ? true : r.status === 'processando' ? null : false,
    `${r.codigo_status ? r.codigo_status + ' — ' : ''}${r.motivo || r.status}`, usuario);
}

// ------------------------------------------------------------
// Ações
// ------------------------------------------------------------
async function emitir(pedido_id: string, usuario: string) {
  const { data: reg, error } = await supabase.rpc('nfe_registrar_tentativa', { p_pedido_id: pedido_id, p_usuario: usuario });
  if (error) return { ok: false, erro: error.message };
  if (!reg.ok) return { ok: false, pendencias: reg.pendencias };
  const nota = await lerNota(reg.nota_id);
  let resultado: ResultadoEmissao;
  try {
    resultado = await provedorPara(nota.provedor).emitir(nota);
  } catch (e) {
    // falha de comunicação: a nota fica "erro" com o MESMO número — "Tentar de novo" reaproveita
    resultado = { status: 'erro', motivo: 'Falha ao falar com a plataforma: ' + (e as Error).message };
  }
  await aplicarResultado(nota, resultado, usuario);
  return { ok: resultado.status === 'autorizada' || resultado.status === 'processando', nota: await lerNota(nota.id) };
}

async function consultar(nota_id: string, usuario: string) {
  const nota = await lerNota(nota_id);
  if (!['processando', 'erro'].includes(nota.status)) return { ok: true, nota };
  const r = await provedorPara(nota.provedor).consultar(nota);
  if (r.status !== nota.status || r.chave !== nota.chave) await aplicarResultado(nota, r, usuario);
  return { ok: true, nota: await lerNota(nota_id) };
}

async function cancelar(nota_id: string, justificativa: string, usuario: string) {
  const just = String(justificativa || '').trim().replace(/\s+/g, ' ');
  if (just.length < 15 || just.length > 255) return { ok: false, erro: 'A justificativa precisa ter de 15 a 255 caracteres (regra da SEFAZ).' };
  const nota = await lerNota(nota_id);
  if (nota.status !== 'autorizada') return { ok: false, erro: `Só nota autorizada pode ser cancelada (esta está: ${nota.status}).` };
  const horas = (Date.now() - new Date(nota.data_autorizacao || nota.data_emissao).getTime()) / 36e5;
  if (horas > 24) {
    return { ok: false, erro: `Passaram ${Math.floor(horas)}h da autorização. Em SP o cancelamento comum vale só até 24h — fale com o contador (pode ser preciso nota de devolução/estorno).` };
  }
  await supabase.from('notas_fiscais').update({ status: 'cancelando', updated_at: new Date().toISOString() }).eq('id', nota.id);
  let r: ResultadoCancelamento;
  try {
    r = await provedorPara(nota.provedor).cancelar(nota, just);
  } catch (e) {
    r = { ok: false, status: 'autorizada', motivo: (e as Error).message };
  }
  const upd: Record<string, unknown> = { status: r.status, updated_at: new Date().toISOString() };
  if (r.ok && r.status === 'cancelada') {
    upd.cancelada_em = new Date().toISOString();
    upd.motivo_cancelamento = just;
    upd.protocolo_cancelamento = r.protocolo ?? null;
    if (r.xml) {
      const c = `${nota.ambiente}/${String(nota.data_emissao).slice(0, 7)}/${nota.chave}-cancelamento.xml`;
      await salvarArquivo(c, r.xml, 'application/xml');
      upd.xml_cancelamento_path = c;
    }
  }
  await supabase.from('notas_fiscais').update(upd).eq('id', nota.id);
  await evento(nota.id, 'cancelamento', r.ok, r.motivo || r.status, usuario, { justificativa: just });
  return r.ok ? { ok: true, nota: await lerNota(nota.id) } : { ok: false, erro: r.motivo || 'Cancelamento não aceito.' };
}

async function enviarEmail(nota_id: string, email: string | undefined, usuario: string) {
  const nota = await lerNota(nota_id);
  if (nota.status !== 'autorizada') return { ok: false, erro: 'Só nota autorizada pode ser enviada por e-mail.' };
  const destino = String(email || nota.destinatario_email || '').trim();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(destino)) return { ok: false, erro: 'E-mail do cliente vazio ou inválido.' };
  const r = await provedorPara(nota.provedor).enviarEmail(nota, destino);
  if (r.ok && nota.ambiente !== 'simulacao') {
    await supabase.from('notas_fiscais').update({ email_enviado_em: new Date().toISOString(), email_enviado_para: destino }).eq('id', nota.id);
  }
  await evento(nota.id, 'email', r.ok, r.mensagem, usuario, { para: destino });
  return { ok: r.ok, mensagem: r.mensagem, nota: await lerNota(nota.id) };
}

async function limparSimulacao(usuario: string) {
  // apaga os arquivos da pasta simulacao/ (por mês) e depois as linhas
  const { data: meses } = await supabase.storage.from(BUCKET).list('simulacao', { limit: 1000 });
  let arquivos = 0;
  for (const m of meses || []) {
    for (;;) {
      const { data: lista } = await supabase.storage.from(BUCKET).list(`simulacao/${m.name}`, { limit: 1000 });
      if (!lista || !lista.length) break;
      await supabase.storage.from(BUCKET).remove(lista.map((a) => `simulacao/${m.name}/${a.name}`));
      arquivos += lista.length;
      if (lista.length < 1000) break;
    }
  }
  const { data: n, error } = await supabase.rpc('nfe_limpar_simulacao');
  if (error) return { ok: false, erro: error.message };
  await evento(null, 'simulacao', true, `Notas de simulação apagadas: ${n} (arquivos: ${arquivos}). Numeração de simulação voltou para 1.`, usuario);
  return { ok: true, notas: n, arquivos };
}

// ------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return resposta({ ok: false, erro: 'Use POST.' }, 405);

  // login obrigatório (o token do usuário vem no header Authorization)
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: u, error: errU } = token ? await supabase.auth.getUser(token) : { data: null, error: new Error('sem token') } as any;
  if (errU || !u?.user) return resposta({ ok: false, erro: 'Faça login no ERP para usar as notas fiscais.' }, 401);
  const usuario = u.user.email || u.user.id;

  let corpo: any = {};
  try { corpo = await req.json(); } catch { return resposta({ ok: false, erro: 'Corpo inválido.' }, 400); }

  try {
    switch (corpo.acao) {
      case 'emitir':           return resposta(await emitir(String(corpo.pedido_id || ''), usuario));
      case 'consultar':        return resposta(await consultar(String(corpo.nota_id || ''), usuario));
      case 'cancelar':         return resposta(await cancelar(String(corpo.nota_id || ''), corpo.justificativa, usuario));
      case 'email':            return resposta(await enviarEmail(String(corpo.nota_id || ''), corpo.email, usuario));
      case 'limpar_simulacao': return resposta(await limparSimulacao(usuario));
      default:                 return resposta({ ok: false, erro: 'Ação desconhecida.' }, 400);
    }
  } catch (e) {
    console.error(e);
    return resposta({ ok: false, erro: (e as Error).message || String(e) }, 500);
  }
});
