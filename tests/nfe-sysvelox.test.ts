// Testes da Edge Function "nfe" — parte SysVelox (série + informações complementares).
// Roda sem rede: o fetch do Supabase e o da SysVelox são simulados aqui.
//   deno test --allow-env --allow-read tests/nfe-sysvelox.test.ts
import nodeAssert from 'node:assert/strict';
const assert = (cond: unknown, msg?: string) => nodeAssert.ok(cond, msg);
const assertEquals = (a: unknown, b: unknown, msg?: string) => nodeAssert.deepStrictEqual(a, b, msg);

const CNPJ = '61352525000180';
const INFO = 'Documento emitido por ME ou EPP optante pelo Simples Nacional. Não gera direito a crédito fiscal de IPI.';
const CONFIG: Record<string, unknown> = {
  id: 1, razao_social: 'E-FACTORY GROUP LTDA', nome_fantasia: 'E-Factory', cnpj: CNPJ, ie: '154510870117', im: '20945577',
  crt: 1, logradouro: 'Rua Campos Salles', numero: '548', complemento: null, bairro: 'Centro', cep: '14015110',
  municipio: 'Ribeirão Preto', codigo_municipio: '3543402', uf: 'SP', ambiente: 'homologacao', provedor: 'sysvelox', serie: 3,
  natureza_operacao: 'Venda de mercadorias', cfop_padrao_dentro_uf: '5102', csosn_padrao: '102', cst_pis_padrao: '99',
  cst_cofins_padrao: '99', indicador_presenca_fisica: 2, info_complementar: INFO,
};

// ---------- estado simulado ----------
let cfg: Record<string, unknown>;
let empresa: Record<string, unknown>;
let chamadas: { metodo: string; url: string; corpo?: any; headers?: Headers }[];
let putEmpresaStatus = 200;
let putIgnora = false;          // SysVelox responde 200 mas não grava
let nota: Record<string, unknown>;

function reset() {
  cfg = structuredClone(CONFIG);
  empresa = {
    id: '061eacfe-6f82-4392-9502-d1907c68207e', cnpj: CNPJ, razao_social: 'E-FACTORY GROUP LTDA', crt: 1, uf: 'SP',
    serie_nfe: 1, serie_nfce: 1, numeracao: [
      { modelo: 55, serie: 1, ambiente: 'test', ultimo_numero: 1 },
      { modelo: 65, serie: 1, ambiente: 'test', ultimo_numero: 0 },
    ],
  };
  chamadas = []; putEmpresaStatus = 200; putIgnora = false;
  nota = {
    id: '11111111-1111-1111-1111-111111111111', provedor: 'sysvelox', ambiente: 'homologacao', serie: 3, numero: null,
    cnpj_emitente: CNPJ, status: 'processando', idem_rodada: 1, data_emissao: '2026-11-19T12:00:00Z',
    dados: {
      natureza_operacao: 'Venda de mercadorias', consumidor_final: 1, indicador_presenca: 1,
      destinatario: { documento: '11222333000181', nome: 'CLIENTE', indicador_ie: 9, logradouro: 'Av', numero: '1', bairro: 'C',
        codigo_municipio: '3550308', municipio: 'São Paulo', uf: 'SP', cep: '01001000' },
      itens: [{ descricao: 'CAIXA', ncm: '48191000', cfop: '5102', unidade: 'UN', quantidade: 2, valor_unitario: 10.5,
        csosn: '102', cst_pis: '99', cst_cofins: '99', origem: 0 }],
      totais: { frete: 0, desconto: 0 }, transporte: { modalidade_frete: 9 }, pagamento: { forma: 'pix' },
      informacoes_complementares: INFO,
    },
  };
}

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'content-type': 'application/json' } });

globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  const metodo = (init?.method || (input instanceof Request ? input.method : 'GET')).toUpperCase();
  const headers = new Headers(init?.headers || (input instanceof Request ? input.headers : undefined));
  let corpo: any = undefined;
  if (init?.body && typeof init.body === 'string') { try { corpo = JSON.parse(init.body); } catch { corpo = init.body; } }
  chamadas.push({ metodo, url, corpo, headers });
  const u = new URL(url);

  // ---------- Supabase ----------
  if (u.host === 'sb.local') {
    if (u.pathname === '/auth/v1/user') return json({ id: 'u1', email: 'joao@teste', aud: 'authenticated' });
    const umObjeto = (headers.get('accept') || '').includes('vnd.pgrst.object');
    if (u.pathname === '/rest/v1/fiscal_config') return json(umObjeto ? cfg : [cfg]);
    if (u.pathname === '/rest/v1/nfe_eventos') return new Response(null, { status: 201 });
    if (u.pathname === '/rest/v1/rpc/nfe_registrar_tentativa') return json({ ok: true, nota_id: nota.id });
    if (u.pathname === '/rest/v1/notas_fiscais') {
      if (metodo === 'PATCH') { Object.assign(nota, corpo); return new Response(null, { status: 204 }); }
      return json(umObjeto ? nota : [nota]);
    }
    if (u.pathname.startsWith('/storage/v1/object/')) return json({ Key: 'ok' });
    return json({ message: 'rota não simulada ' + u.pathname }, 404);
  }

  // ---------- SysVelox ----------
  if (u.host === 'api.sysvelox.com') {
    assert((headers.get('authorization') || '').startsWith('Bearer sk_test_'), 'sempre chave de teste');
    if (u.pathname === `/v1/empresas/${CNPJ}` && metodo === 'GET') return json(empresa);
    if (u.pathname === `/v1/empresas/${CNPJ}` && metodo === 'PUT') {
      if (putEmpresaStatus !== 200) return json({ error: { code: 'FORBIDDEN_ENVIRONMENT', message: 'Chave de teste não grava isso.' } }, putEmpresaStatus);
      if (!putIgnora) empresa = { ...empresa, serie_nfe: corpo.serie_nfe };
      return json(empresa);
    }
    if (u.pathname.startsWith('/v1/empresas/')) return json({ error: { code: 'COMPANY_NOT_FOUND', message: 'Empresa não encontrada.' } }, 404);
    if (u.pathname === '/v1/nfe' && metodo === 'POST') return json({ id: 'nf_teste', tipo: 'nfe', status: 'processando' }, 202);
    if (u.pathname === '/v1/notas/nf_teste') return json({ id: 'nf_teste', status: 'authorized', numero: 1, serie: Number(empresa.serie_nfe), chave_acesso: '3'.repeat(44), protocolo: '999000000000001', simulado: true });
    if (u.pathname === '/v1/notas/nf_teste/xml') return new Response(`<nfeProc><infCpl>${INFO}</infCpl></nfeProc>`, { headers: { 'content-type': 'application/xml' } });
    if (u.pathname === '/v1/notas/nf_teste/danfe') return new Response(new Uint8Array([37, 80, 68, 70]), { headers: { 'content-type': 'application/pdf' } });
  }
  return json({ error: 'rota não simulada: ' + metodo + ' ' + url }, 500);
}) as typeof fetch;

Deno.env.set('SUPABASE_URL', 'http://sb.local');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'service-role-falsa');
Deno.env.set('SYSVELOX_API_KEY', 'sk_test_falsa');
Deno.env.set('SYSVELOX_COMPANY_ID', '061eacfe-6f82-4392-9502-d1907c68207e');

let handler: (req: Request) => Promise<Response>;
// deno-lint-ignore no-explicit-any
(Deno as any).serve = (h: any) => { handler = h; return { finished: Promise.resolve(), shutdown() {} }; };
await import('../supabase/functions/nfe.ts');

async function chamar(corpo: unknown) {
  const r = await handler(new Request('http://fn/nfe', { method: 'POST', headers: { Authorization: 'Bearer token-do-usuario' }, body: JSON.stringify(corpo) }));
  return await r.json();
}
const sv = (metodo: string, trecho: string) => chamadas.filter((c) => c.metodo === metodo && c.url.includes('api.sysvelox.com') && c.url.includes(trecho));

Deno.test('status: mostra a série da SysVelox x ERP e só a numeração da NF-e (modelo 55)', async () => {
  reset();
  const r = await chamar({ acao: 'sysvelox_status' });
  assertEquals(r.ok, true);
  assertEquals(r.serie_sysvelox, 1);
  assertEquals(r.serie_erp, 3);
  assertEquals(r.bate, false);
  assertEquals(r.numeracao, [{ serie: 1, ambiente: 'test', ultimo_numero: 1 }]);
  assertEquals(sv('PUT', '/v1/empresas').length, 0, 'consultar não grava nada');
});

Deno.test('trocar série: manda o cadastro completo do ERP + série 3, mantém NFC-e, e confere depois', async () => {
  reset();
  const r = await chamar({ acao: 'sysvelox_serie' });
  assertEquals(r.ok, true, JSON.stringify(r));
  assertEquals(r.bate, true);
  assertEquals(r.serie_sysvelox, 3);
  const puts = sv('PUT', `/v1/empresas/${CNPJ}`);
  assertEquals(puts.length, 1);
  assertEquals(puts[0].corpo, {
    razao_social: 'E-FACTORY GROUP LTDA', nome_fantasia: 'E-Factory', inscricao_estadual: '154510870117', inscricao_municipal: '20945577',
    crt: 1, uf: 'SP', ibge_codigo_municipio: '3543402', logradouro: 'Rua Campos Salles', numero: '548', complemento: null,
    bairro: 'Centro', municipio_nome: 'Ribeirão Preto', cep: '14015110', serie_nfe: 3, serie_nfce: 1,
  });
  assertEquals(sv('GET', `/v1/empresas/${CNPJ}`).length, 2, 'lê antes e confere depois');
  assert(chamadas.some((c) => c.url.includes('/rest/v1/nfe_eventos') && c.corpo?.tipo === 'sysvelox_serie' && c.corpo?.sucesso === true));
});

Deno.test('trocar série quando já bate: não grava nada', async () => {
  reset(); empresa.serie_nfe = 3;
  const r = await chamar({ acao: 'sysvelox_serie' });
  assertEquals(r.ok, true);
  assertEquals(sv('PUT', '/v1/empresas').length, 0);
});

Deno.test('trocar série: SysVelox recusa (403) → erro claro, nada muda', async () => {
  reset(); putEmpresaStatus = 403;
  const r = await chamar({ acao: 'sysvelox_serie' });
  assertEquals(r.ok, false);
  assert(String(r.erro).includes('FORBIDDEN_ENVIRONMENT'), r.erro);
  assertEquals(empresa.serie_nfe, 1);
});

Deno.test('trocar série: SysVelox diz OK mas não grava → ERP avisa que não confirmou', async () => {
  reset(); putIgnora = true;
  const r = await chamar({ acao: 'sysvelox_serie' });
  assertEquals(r.ok, false);
  assert(String(r.erro).includes('não confirmou'), r.erro);
});

Deno.test('trocar série: cadastro incompleto no ERP → nem chama a SysVelox para gravar', async () => {
  reset(); cfg.logradouro = null;
  const r = await chamar({ acao: 'sysvelox_serie' });
  assertEquals(r.ok, false);
  assert(String(r.erro).includes('rua'), r.erro);
  assertEquals(sv('PUT', '/v1/empresas').length, 0);
});

Deno.test('trocar série: série 0 do ERP é recusada (SysVelox aceita 1 a 999)', async () => {
  reset(); cfg.serie = 0;
  const r = await chamar({ acao: 'sysvelox_serie' });
  assertEquals(r.ok, false);
  assertEquals(sv('PUT', '/v1/empresas').length, 0);
});

Deno.test('emitir venda: manda informacoes_complementares (texto do Simples) e respeita a série', async () => {
  reset(); empresa.serie_nfe = 3;
  const r = await chamar({ acao: 'emitir', pedido_id: 'p1' });
  assertEquals(r.ok, true, JSON.stringify(r));
  const post = sv('POST', '/v1/nfe')[0];
  assertEquals(post.corpo.informacoes_complementares, INFO);
  assertEquals(post.corpo.items[0].unit_price_cents, 1050);
  assertEquals(post.headers?.get('idempotency-key'), `erp-nfe-${nota.id}-1`);
  assertEquals(nota.status, 'autorizada');
});

Deno.test('emitir venda: série diferente na SysVelox → bloqueia antes de enviar', async () => {
  reset();
  const r = await chamar({ acao: 'emitir', pedido_id: 'p1' });
  assertEquals(r.ok, false);
  assertEquals(sv('POST', '/v1/nfe').length, 0, 'não pode enviar nota na série errada');
  assertEquals(nota.codigo_status, 'SERIE_DIFERENTE');
});

Deno.test('teste SysVelox: envia o texto do Simples e avisa quando a série não bate', async () => {
  reset();
  const r = await chamar({ acao: 'teste_sysvelox' });
  assertEquals(r.ok, true, JSON.stringify(r));
  assertEquals(sv('POST', '/v1/nfe')[0].corpo.informacoes_complementares, INFO);
  assert(r.passos.some((p: string) => p.includes('Série diferente')), r.passos.join('\n'));
  assert(r.passos.some((p: string) => p.includes('optante pelo Simples')));
});

Deno.test('teste SysVelox: sem aviso de série quando bate', async () => {
  reset(); empresa.serie_nfe = 3;
  const r = await chamar({ acao: 'teste_sysvelox' });
  assert(!r.passos.some((p: string) => p.includes('Série diferente')));
});
