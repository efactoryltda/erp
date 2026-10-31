-- ============================================================
-- ERP E-Factory — LOTE 11 — NOTA FISCAL (NF-e modelo 55) + SysVelox
--   (o nome "Lote 9" já foi usado pelas tags de canal/envio)
--   • fiscal_config ............ empresa emitente, ambiente, série (3),
--                                plataforma (simulacao | sysvelox),
--                                CST PIS/COFINS padrão 99 (o mesmo que o
--                                Tiny usa nas notas próprias da E-Factory —
--                                conferido no XML da NF-e nº 34, série 1).
--   • nfe_numeracao ............ numeração da SIMULAÇÃO. Na SysVelox o
--                                número é dado pela própria SysVelox.
--   • produtos (+ colunas) ..... origem e "fiscal conferido pelo contador".
--                                (NCM, CEST, CSOSN e CFOP já existem.)
--   • clientes (+ colunas) ..... endereço estruturado, IE, consumidor final.
--   • notas_fiscais / nfe_eventos / bucket privado notas-fiscais.
--   • Filtro "com NF / sem NF": funções _v4 novas (as _v3 ficam intactas).
--   • Trava: pedido com NF-e de PRODUÇÃO viva não pode ser cancelado nem
--     excluído antes de cancelar a nota.
-- NÃO mexe em faturamento, estoque, contas a receber nem nos dados fiscais
-- já cadastrados nos produtos. Confere sozinho + teste (desfeito no fim).
-- Cole TUDO no Supabase → SQL Editor → RUN ("Run without RLS" se avisar).
-- ============================================================
begin;

-- ---------- pré-condições ----------
do $$
begin
  if (select count(*) from clientes) <> 0 then
    raise exception 'PARADO: a tabela clientes já tem dados — revisar o lote antes. Nada foi aplicado.';
  end if;
  if to_regclass('public.notas_fiscais') is not null then
    raise exception 'PARADO: notas_fiscais já existe. Nada foi aplicado.';
  end if;
end $$;

create temp table _antes on commit drop as
  select (select coalesce(sum(valor_total) filter (where status = 'confirmado'), 0) from pedidos_venda) as fat,
         (select count(*) from pedidos_venda) as n_ped,
         (select coalesce(sum(quantidade), 0) from estoque_saldos) as estoque,
         (select count(*) from movimentacoes_estoque) as n_mov,
         (select count(*) from lancamentos_financeiros) as n_lanc,
         (select count(*) from produtos) as n_prod,
         (select md5(string_agg(id || coalesce(ncm,'') || coalesce(cest,'') || coalesce(csosn,'') || coalesce(cfop_dentro_sp,'') || coalesce(cfop_fora_sp,''), ',' order by id)) from produtos) as fiscal_prod;

-- ============================================================
-- 1) CONFIGURAÇÃO FISCAL (linha única)
-- ============================================================
create table fiscal_config (
  id                        smallint primary key default 1 check (id = 1),
  razao_social              text,
  nome_fantasia             text,
  cnpj                      text check (cnpj is null or cnpj ~ '^\d{14}$'),
  ie                        text,
  im                        text,
  crt                       smallint not null default 1 check (crt in (1, 2, 3, 4)),   -- 1 = Simples Nacional
  logradouro                text,
  numero                    text,
  complemento               text,
  bairro                    text,
  cep                       text check (cep is null or cep ~ '^\d{8}$'),
  municipio                 text,
  codigo_municipio          text check (codigo_municipio is null or codigo_municipio ~ '^\d{7}$'),
  uf                        text not null default 'SP' check (uf ~ '^[A-Z]{2}$'),
  telefone                  text,
  email                     text,
  ambiente                  text not null default 'simulacao' check (ambiente in ('simulacao', 'homologacao', 'producao')),
  provedor                  text not null default 'simulacao' check (provedor in ('simulacao', 'sysvelox')),
  serie                     int  not null default 3 check (serie between 0 and 999),
  natureza_operacao         text not null default 'Venda de mercadorias',
  cfop_padrao_dentro_uf     text not null default '5102' check (cfop_padrao_dentro_uf ~ '^5\d{3}$'),
  cfop_padrao_fora_uf       text not null default '6102' check (cfop_padrao_fora_uf ~ '^6\d{3}$'),
  csosn_padrao              text not null default '102' check (csosn_padrao ~ '^\d{3}$'),
  cst_pis_padrao            text not null default '99' check (cst_pis_padrao ~ '^\d{2}$'),
  cst_cofins_padrao         text not null default '99' check (cst_cofins_padrao ~ '^\d{2}$'),
  indicador_presenca_fisica smallint not null default 2 check (indicador_presenca_fisica in (0, 1, 2, 3, 4, 5, 9)),
  info_complementar         text default 'Documento emitido por ME ou EPP optante pelo Simples Nacional. Não gera direito a crédito fiscal de IPI.',
  email_copia               text,
  updated_at                timestamptz not null default now(),
  updated_by                text,
  -- simulação só com o "provedor" simulação, e vice-versa
  constraint fiscal_config_simulacao check ((ambiente = 'simulacao') = (provedor = 'simulacao'))
);
comment on table fiscal_config is 'Dados da empresa emitente da NF-e e padrões do módulo fiscal (linha única, id = 1).';

-- dados já conhecidos (conferir/completar na tela): CNPJ tirado da chave
-- das notas da E-Factory no Tiny; Ribeirão Preto = IBGE 3543402.
insert into fiscal_config (id, razao_social, cnpj, crt, municipio, codigo_municipio, uf)
values (1, 'E-FACTORY GROUP LTDA', '61352525000180', 1, 'Ribeirão Preto', '3543402', 'SP');

alter table fiscal_config enable row level security;
create policy fiscal_config_select on fiscal_config for select to authenticated using (true);
create policy fiscal_config_update on fiscal_config for update to authenticated using (true) with check (true);

-- ============================================================
-- 2) NUMERAÇÃO (último número usado por ambiente + série)
-- ============================================================
create table nfe_numeracao (
  ambiente       text not null check (ambiente in ('simulacao', 'homologacao', 'producao')),
  serie          int  not null check (serie between 0 and 999),
  ultimo_numero  int  not null default 0 check (ultimo_numero between 0 and 999999999),
  updated_at     timestamptz not null default now(),
  primary key (ambiente, serie)
);
insert into nfe_numeracao (ambiente, serie, ultimo_numero) values
  ('simulacao', 3, 0), ('homologacao', 3, 0), ('producao', 3, 0);
alter table nfe_numeracao enable row level security;
create policy nfe_numeracao_select on nfe_numeracao for select to authenticated using (true);

-- ============================================================
-- 3) PRODUTOS — campos fiscais
-- ============================================================
alter table produtos
  add column origem        smallint not null default 0 check (origem between 0 and 8),
  add column ncm_validado  boolean not null default false;
comment on column produtos.ncm_validado is 'true = NCM/CFOP/CSOSN conferidos pelo contador. Sem isso a nota NÃO sai em produção.';

-- ============================================================
-- 4) CLIENTES — endereço estruturado (tabela vazia hoje)
-- ============================================================
alter table clientes
  add column tipo_pessoa      text check (tipo_pessoa in ('F', 'J')),
  add column ie               text,
  add column indicador_ie     smallint not null default 9 check (indicador_ie in (1, 2, 9)),  -- 1 contribuinte, 2 isento, 9 não contribuinte
  add column consumidor_final boolean  not null default true,   -- compra para uso/consumo próprio (não revenda). Tiny marcava "Sim".
  add column logradouro       text,
  add column numero           text,
  add column complemento      text,
  add column bairro           text,
  add column cep              text check (cep is null or cep ~ '^\d{8}$'),
  add column municipio        text,
  add column codigo_municipio text check (codigo_municipio is null or codigo_municipio ~ '^\d{7}$'),
  add column uf               text check (uf is null or uf ~ '^[A-Z]{2}$'),
  add column ativo            boolean not null default true,
  add column updated_at       timestamptz not null default now();
alter table clientes add constraint clientes_documento_formato
  check (documento is null or documento ~ '^(\d{11}|\d{14})$');
create unique index clientes_documento_unico on clientes (documento) where documento is not null;

create or replace function clientes_normalizar() returns trigger language plpgsql as $$
begin
  new.documento := nullif(regexp_replace(coalesce(new.documento, ''), '\D', '', 'g'), '');
  new.cep       := nullif(regexp_replace(coalesce(new.cep, ''), '\D', '', 'g'), '');
  new.codigo_municipio := nullif(regexp_replace(coalesce(new.codigo_municipio, ''), '\D', '', 'g'), '');
  new.uf        := nullif(upper(trim(coalesce(new.uf, ''))), '');
  new.ie        := nullif(upper(regexp_replace(coalesce(new.ie, ''), '[^0-9A-Za-z]', '', 'g')), '');
  new.nome      := trim(new.nome);
  if new.documento is not null then
    new.tipo_pessoa := case when length(new.documento) = 14 then 'J' else 'F' end;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger trg_clientes_normalizar before insert or update on clientes
  for each row execute function clientes_normalizar();

-- ============================================================
-- 5) NOTAS FISCAIS + EVENTOS
-- ============================================================
create table notas_fiscais (
  id                      uuid primary key default gen_random_uuid(),
  origem                  text not null default 'erp' check (origem in ('erp', 'ml')),   -- 'ml' = importada do Faturador do ML (fase seguinte)
  pedido_id               uuid references pedidos_venda(id) on delete restrict,
  cliente_id              uuid references clientes(id) on delete restrict,
  canal                   text,
  ambiente                text not null check (ambiente in ('simulacao', 'homologacao', 'producao')),
  modelo                  smallint not null default 55,
  serie                   int not null,
  numero                  int,           -- SysVelox: preenchido quando a nota é autorizada
  cnpj_emitente           text not null,
  chave                   text check (chave is null or chave ~ '^\d{44}$'),
  status                  text not null check (status in ('processando', 'autorizada', 'rejeitada', 'erro', 'cancelando', 'cancelada')),
  codigo_status           text,          -- cStat da SEFAZ (100 = autorizada)
  motivo                  text,          -- mensagem da SEFAZ / da plataforma
  protocolo               text,
  data_emissao            timestamptz,
  data_autorizacao        timestamptz,
  natureza_operacao       text,
  destinatario_nome       text,
  destinatario_documento  text,
  destinatario_uf         text,
  destinatario_email      text,
  valor_produtos          numeric(14,2),
  valor_frete             numeric(14,2),
  valor_desconto          numeric(14,2),
  valor_total             numeric(14,2),
  dados                   jsonb,          -- foto exata do que foi enviado
  provedor                text,
  provedor_ref            text,           -- id da nota na plataforma emissora
  xml_path                text,           -- arquivo no bucket notas-fiscais
  pdf_path                text,
  xml_cancelamento_path   text,
  motivo_cancelamento     text,
  protocolo_cancelamento  text,
  cancelada_em            timestamptz,
  email_enviado_em        timestamptz,
  email_enviado_para      text,
  emitida_por             text,
  tentativas              int not null default 1,
  idem_rodada             int not null default 1,   -- muda a Idempotency-Key só depois de rejeição/erro de validação
  simulado                boolean,                  -- SysVelox sandbox devolve true
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint notas_fiscais_numero_unico unique (cnpj_emitente, ambiente, modelo, serie, numero)
);
-- um pedido só pode ter UMA nota "viva" por ambiente (cancelada libera nova)
create unique index notas_fiscais_uma_por_pedido on notas_fiscais (pedido_id, ambiente)
  where origem = 'erp' and status <> 'cancelada';
create index notas_fiscais_emissao on notas_fiscais (ambiente, data_emissao desc);
create index notas_fiscais_pedido on notas_fiscais (pedido_id);

alter table notas_fiscais enable row level security;
create policy notas_fiscais_select on notas_fiscais for select to authenticated using (true);
-- (sem policy de escrita: só a Edge Function, com service_role, grava)

create table nfe_eventos (
  id            bigint generated always as identity primary key,
  nota_id       uuid references notas_fiscais(id) on delete cascade,
  tipo          text not null,      -- emissao, autorizada, rejeitada, erro, consulta, cancelamento, email, numeracao, config
  sucesso       boolean,
  mensagem      text,
  detalhe       jsonb,
  usuario_email text,
  created_at    timestamptz not null default now()
);
create index nfe_eventos_nota on nfe_eventos (nota_id, created_at desc);
alter table nfe_eventos enable row level security;
create policy nfe_eventos_select on nfe_eventos for select to authenticated using (true);

-- ============================================================
-- 6) ARMAZENAMENTO (XML/PDF) — bucket privado
-- ============================================================
insert into storage.buckets (id, name, public) values ('notas-fiscais', 'notas-fiscais', false)
  on conflict (id) do nothing;
create policy "notas_fiscais_leitura_logado" on storage.objects for select to authenticated
  using (bucket_id = 'notas-fiscais');

-- ============================================================
-- 7) FUNÇÕES
-- ============================================================

-- 7a) Monta a nota de um pedido (sem gravar nada) e lista o que falta.
--     Usada pela tela (pré-visualização) e pelo servidor (na hora de emitir).
create or replace function nfe_preparar(p_pedido_id uuid)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  c fiscal_config;
  p pedidos_venda;
  cli clientes;
  pend text[] := '{}';
  avisos text[] := '{}';
  itens jsonb := '[]'::jsonb;
  r record;
  ex record;
  n_itens int;
  i int := 0;
  v_dentro boolean := true;
  v_cfop text; v_csosn text; v_ncm text;
  v_frete numeric; v_desc numeric;
  rest_frete numeric; rest_desc numeric;
  soma_itens numeric := 0;
  v_total numeric;
  v_consumidor_final smallint;
  v_presenca smallint;
begin
  select * into c from fiscal_config where id = 1;
  select * into p from pedidos_venda where id = p_pedido_id;
  if not found then
    return jsonb_build_object('ok', false, 'pendencias', jsonb_build_array('Pedido não encontrado.'), 'avisos', '[]'::jsonb);
  end if;

  -- empresa emitente
  if coalesce(c.razao_social, '') = '' then pend := array_append(pend, 'Configuração fiscal: falta a razão social da empresa.'); end if;
  if coalesce(c.cnpj, '') !~ '^\d{14}$' then pend := array_append(pend, 'Configuração fiscal: CNPJ da empresa inválido.'); end if;
  if coalesce(c.ie, '') = '' then pend := array_append(pend, 'Configuração fiscal: falta a Inscrição Estadual da empresa.'); end if;
  if coalesce(c.logradouro, '') = '' or coalesce(c.numero, '') = '' or coalesce(c.bairro, '') = '' then
    pend := array_append(pend, 'Configuração fiscal: endereço da empresa incompleto (rua, número e bairro).'); end if;
  if coalesce(c.cep, '') !~ '^\d{8}$' then pend := array_append(pend, 'Configuração fiscal: CEP da empresa inválido.'); end if;
  if coalesce(c.codigo_municipio, '') !~ '^\d{7}$' or coalesce(c.municipio, '') = '' then
    pend := array_append(pend, 'Configuração fiscal: município da empresa (nome e código IBGE).'); end if;

  -- pedido
  if p.status <> 'confirmado' then pend := array_append(pend, 'O pedido não está confirmado (status: ' || p.status || ').'); end if;
  if p.canal::text not in ('loja_fisica', 'loja_online') then
    pend := array_append(pend, 'Vendas do Mercado Livre e da Shopee têm a nota emitida pelo próprio marketplace — não emitir pelo ERP.'); end if;

  select * into ex from notas_fiscais
   where pedido_id = p.id and origem = 'erp' and ambiente = c.ambiente
     and status in ('processando', 'autorizada', 'cancelando')
   limit 1;
  if found then
    pend := array_append(pend, format('Este pedido já tem a nota nº %s (série %s) — status: %s.', ex.numero, ex.serie, ex.status));
  end if;

  -- destinatário
  if p.cliente_id is null then
    pend := array_append(pend, 'Escolha o cliente (destinatário) da nota.');
  else
    select * into cli from clientes where id = p.cliente_id;
    if coalesce(cli.documento, '') !~ '^(\d{11}|\d{14})$' then pend := array_append(pend, 'Cliente: CPF/CNPJ inválido ou vazio.'); end if;
    if coalesce(cli.nome, '') = '' then pend := array_append(pend, 'Cliente: falta o nome / razão social.'); end if;
    if coalesce(cli.logradouro, '') = '' or coalesce(cli.numero, '') = '' or coalesce(cli.bairro, '') = '' then
      pend := array_append(pend, 'Cliente: endereço incompleto (rua, número e bairro).'); end if;
    if coalesce(cli.cep, '') !~ '^\d{8}$' then pend := array_append(pend, 'Cliente: CEP inválido.'); end if;
    if coalesce(cli.codigo_municipio, '') !~ '^\d{7}$' or coalesce(cli.municipio, '') = '' or coalesce(cli.uf, '') = '' then
      pend := array_append(pend, 'Cliente: município/UF (com código IBGE) — use a busca pelo CEP.'); end if;
    if cli.indicador_ie = 1 and coalesce(cli.ie, '') in ('', 'ISENTO') then
      pend := array_append(pend, 'Cliente marcado como contribuinte de ICMS, mas sem Inscrição Estadual.'); end if;
    if coalesce(cli.email, '') = '' then avisos := array_append(avisos, 'Cliente sem e-mail: a nota não será enviada por e-mail automaticamente.'); end if;
    v_dentro := (coalesce(cli.uf, c.uf) = c.uf);
  end if;

  -- itens (frete e desconto rateados pelo valor de cada item; centavos na última linha)
  select count(*) into n_itens from pedido_itens where pedido_id = p.id;
  if n_itens = 0 then pend := array_append(pend, 'O pedido não tem itens.'); end if;
  rest_frete := coalesce(p.valor_frete, 0);
  rest_desc  := coalesce(p.desconto, 0);

  for r in
    select pi.id, pi.produto_id, pi.quantidade, pi.preco_unitario, pi.subtotal, pi.sku_ml_item,
           pr.sku_interno, pr.nome, pr.ncm, pr.cest, pr.origem, pr.csosn, pr.cfop_dentro_sp, pr.cfop_fora_sp,
           pr.unidade_medida, pr.ncm_validado
      from pedido_itens pi left join produtos pr on pr.id = pi.produto_id
     where pi.pedido_id = p.id
     order by pi.subtotal desc, pi.id
  loop
    i := i + 1;
    soma_itens := soma_itens + coalesce(r.subtotal, 0);
    if i = n_itens then
      v_frete := rest_frete; v_desc := rest_desc;
    else
      v_frete := round(coalesce(p.valor_frete, 0) * r.subtotal / nullif(p.valor_produtos, 0), 2);
      v_desc  := round(coalesce(p.desconto, 0)    * r.subtotal / nullif(p.valor_produtos, 0), 2);
      v_frete := coalesce(v_frete, 0); v_desc := coalesce(v_desc, 0);
      rest_frete := rest_frete - v_frete; rest_desc := rest_desc - v_desc;
    end if;

    if r.produto_id is null then
      pend := array_append(pend, format('Item %s sem produto cadastrado (SKU %s).', i, coalesce(r.sku_ml_item, '?')));
      continue;
    end if;

    v_ncm := regexp_replace(coalesce(r.ncm, ''), '\D', '', 'g');
    if v_ncm !~ '^\d{8}$' then
      pend := array_append(pend, format('%s (%s): sem NCM válido (8 dígitos) — preencha na aba Produtos.', r.nome, r.sku_interno));
    elsif not r.ncm_validado then
      if c.ambiente = 'producao' then
        pend := array_append(pend, format('%s (%s): NCM ainda não validado pelo contador (obrigatório em produção).', r.nome, r.sku_interno));
      else
        avisos := array_append(avisos, format('%s (%s): NCM ainda não validado pelo contador.', r.nome, r.sku_interno));
      end if;
    end if;
    v_cfop  := case when v_dentro then coalesce(nullif(trim(r.cfop_dentro_sp), ''), c.cfop_padrao_dentro_uf)
                    else coalesce(nullif(trim(r.cfop_fora_sp), ''), c.cfop_padrao_fora_uf) end;
    v_csosn := coalesce(nullif(trim(r.csosn), ''), c.csosn_padrao);
    if v_cfop !~ (case when v_dentro then '^5\d{3}$' else '^6\d{3}$' end) then
      pend := array_append(pend, format('%s (%s): CFOP %s não serve para venda %s.', r.nome, r.sku_interno, v_cfop,
                                        case when v_dentro then 'dentro de SP (começa com 5)' else 'para outro estado (começa com 6)' end));
    end if;
    if v_csosn !~ '^\d{3}$' then pend := array_append(pend, format('%s (%s): CSOSN inválido (%s).', r.nome, r.sku_interno, v_csosn)); end if;
    if length(coalesce(nullif(trim(r.unidade_medida), ''), 'UN')) > 6 then
      pend := array_append(pend, format('%s (%s): unidade "%s" tem mais de 6 letras.', r.nome, r.sku_interno, r.unidade_medida));
    end if;
    -- a SysVelox recebe preço em CENTAVOS inteiros: fração de centavo mudaria o valor da nota
    if r.preco_unitario * 100 <> round(r.preco_unitario * 100) then
      pend := array_append(pend, format('%s (%s): preço unitário R$ %s tem fração de centavo — ajuste o preço na venda.', r.nome, r.sku_interno, r.preco_unitario));
    elsif round(r.quantidade * round(r.preco_unitario * 100)) <> round(r.subtotal * 100) then
      pend := array_append(pend, format('%s (%s): quantidade × preço não fecha com o subtotal do item.', r.nome, r.sku_interno));
    end if;

    itens := itens || jsonb_build_object(
      'n', i,
      'produto_id', r.produto_id,
      'codigo', r.sku_interno,
      'descricao', r.nome,
      'ncm', v_ncm,
      'cest', nullif(regexp_replace(coalesce(r.cest, ''), '\D', '', 'g'), ''),
      'origem', r.origem,
      'csosn', v_csosn,
      'cfop', v_cfop,
      'cst_pis', c.cst_pis_padrao,
      'cst_cofins', c.cst_cofins_padrao,
      'unidade', upper(coalesce(nullif(trim(r.unidade_medida), ''), 'UN')),
      'quantidade', r.quantidade,
      'valor_unitario', r.preco_unitario,
      'valor_bruto', round(r.subtotal, 2),
      'valor_frete', v_frete,
      'valor_desconto', v_desc
    );
  end loop;

  if abs(soma_itens - coalesce(p.valor_produtos, 0)) > 0.005 then
    pend := array_append(pend, format('Soma dos itens (%s) diferente do total de produtos do pedido (%s).', soma_itens, p.valor_produtos));
  end if;
  v_total := round(coalesce(p.valor_produtos, 0) + coalesce(p.valor_frete, 0) - coalesce(p.desconto, 0), 2);
  if abs(v_total - coalesce(p.valor_total, 0)) > 0.005 then
    pend := array_append(pend, format('Total calculado da nota (%s) diferente do total do pedido (%s).', v_total, p.valor_total));
  end if;
  if v_total <= 0 then pend := array_append(pend, 'Valor total da nota precisa ser maior que zero.'); end if;

  -- consumidor final: o que estiver no cadastro do cliente; não contribuinte (9) é sempre consumidor final
  v_consumidor_final := case when cli.indicador_ie = 9 or cli.indicador_ie is null or coalesce(cli.consumidor_final, true) then 1 else 0 end;
  v_presenca := case when p.canal::text = 'loja_online' then 2 else c.indicador_presenca_fisica end;

  return jsonb_build_object(
    'ok', cardinality(pend) = 0,
    'pendencias', to_jsonb(pend),
    'avisos', to_jsonb(avisos),
    'dados', jsonb_build_object(
      'ambiente', c.ambiente,
      'provedor', c.provedor,
      'modelo', 55,
      'serie', c.serie,
      'natureza_operacao', c.natureza_operacao,
      'tipo_operacao', 1,                         -- saída
      'finalidade', 1,                            -- normal
      'consumidor_final', v_consumidor_final,
      'indicador_presenca', v_presenca,
      'destino', case when v_dentro then 1 else 2 end,   -- 1 interna, 2 interestadual
      'emitente', jsonb_build_object(
        'cnpj', c.cnpj, 'razao_social', c.razao_social, 'nome_fantasia', c.nome_fantasia,
        'ie', c.ie, 'im', c.im, 'crt', c.crt,
        'logradouro', c.logradouro, 'numero', c.numero, 'complemento', c.complemento, 'bairro', c.bairro,
        'cep', c.cep, 'municipio', c.municipio, 'codigo_municipio', c.codigo_municipio, 'uf', c.uf,
        'telefone', c.telefone, 'email', c.email),
      'destinatario', case when cli.id is null then null else jsonb_build_object(
        'cliente_id', cli.id, 'documento', cli.documento, 'tipo_pessoa', cli.tipo_pessoa, 'nome', cli.nome,
        'ie', cli.ie, 'indicador_ie', cli.indicador_ie,
        'logradouro', cli.logradouro, 'numero', cli.numero, 'complemento', cli.complemento, 'bairro', cli.bairro,
        'cep', cli.cep, 'municipio', cli.municipio, 'codigo_municipio', cli.codigo_municipio, 'uf', cli.uf,
        'telefone', cli.telefone, 'email', cli.email) end,
      'itens', itens,
      'totais', jsonb_build_object(
        'produtos', round(coalesce(p.valor_produtos, 0), 2),
        'frete', round(coalesce(p.valor_frete, 0), 2),
        'desconto', round(coalesce(p.desconto, 0), 2),
        'total', v_total),
      'transporte', jsonb_build_object('modalidade_frete', case when coalesce(p.valor_frete, 0) > 0 then 0 else 9 end),
      'pagamento', jsonb_build_object('forma', p.forma_pagamento, 'condicao', p.condicao_pagamento, 'valor', v_total),
      'informacoes_complementares', c.info_complementar,
      'email_copia', c.email_copia,
      'pedido', jsonb_build_object('id', p.id, 'canal', p.canal, 'data', p.data_pedido)
    )
  );
end $$;
revoke all on function nfe_preparar(uuid) from public, anon;
grant execute on function nfe_preparar(uuid) to authenticated, service_role;

-- 7b) SERVIDOR: registra a tentativa de emissão e decide o número.
--     • nota rejeitada/erro do mesmo pedido → REAPROVEITA o mesmo número
--     • senão → reserva o próximo (+1), atômico (trava a linha da numeração)
--     • nota viva (processando/autorizada/cancelando) → recusa
--     Só a Edge Function (service_role) pode chamar.
create or replace function nfe_registrar_tentativa(p_pedido_id uuid, p_usuario text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  prep jsonb;
  d jsonb;
  ex notas_fiscais;
  v_num int;
  v_id uuid;
  c fiscal_config;
begin
  perform 1 from pedidos_venda where id = p_pedido_id for update;   -- 2 cliques ao mesmo tempo esperam na fila
  if not found then raise exception 'Pedido não encontrado.'; end if;

  prep := nfe_preparar(p_pedido_id);
  if not (prep->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'pendencias', prep->'pendencias');
  end if;
  d := prep->'dados';
  select * into c from fiscal_config where id = 1;

  select * into ex from notas_fiscais
   where pedido_id = p_pedido_id and origem = 'erp' and ambiente = c.ambiente and status in ('rejeitada', 'erro')
   order by created_at desc limit 1
   for update;

  if found and (ex.serie <> c.serie or ex.cnpj_emitente <> c.cnpj) then
    raise exception 'Este pedido tem a nota nº % rejeitada na série % — a série/CNPJ da configuração mudou. Volte a configuração ou fale com o suporte.', ex.numero, ex.serie;
  end if;
  if found then
    update notas_fiscais set
      status = 'processando', codigo_status = null, motivo = null, chave = null, protocolo = null,
      dados = d, provedor = c.provedor, provedor_ref = null, cliente_id = (d->'destinatario'->>'cliente_id')::uuid,
      destinatario_nome = d->'destinatario'->>'nome', destinatario_documento = d->'destinatario'->>'documento',
      destinatario_uf = d->'destinatario'->>'uf', destinatario_email = d->'destinatario'->>'email',
      valor_produtos = (d->'totais'->>'produtos')::numeric, valor_frete = (d->'totais'->>'frete')::numeric,
      valor_desconto = (d->'totais'->>'desconto')::numeric, valor_total = (d->'totais'->>'total')::numeric,
      natureza_operacao = d->>'natureza_operacao', data_emissao = now(), emitida_por = p_usuario,
      tentativas = tentativas + 1, updated_at = now()
    where id = ex.id;
    v_id := ex.id; v_num := ex.numero;
    insert into nfe_eventos (nota_id, tipo, sucesso, mensagem, usuario_email)
      values (v_id, 'emissao', null, format('Nova tentativa (nº %s reaproveitado).', v_num), p_usuario);
  else
    if c.provedor = 'simulacao' then
      update nfe_numeracao set ultimo_numero = ultimo_numero + 1, updated_at = now()
       where ambiente = c.ambiente and serie = c.serie
       returning ultimo_numero into v_num;
      if v_num is null then
        insert into nfe_numeracao (ambiente, serie, ultimo_numero) values (c.ambiente, c.serie, 1);
        v_num := 1;
      end if;
    else
      v_num := null;   -- a plataforma (SysVelox) numera; o ERP grava o número que ela devolver
    end if;
    insert into notas_fiscais (
      origem, pedido_id, cliente_id, canal, ambiente, modelo, serie, numero, cnpj_emitente, status,
      data_emissao, natureza_operacao, destinatario_nome, destinatario_documento, destinatario_uf, destinatario_email,
      valor_produtos, valor_frete, valor_desconto, valor_total, dados, provedor, emitida_por)
    values (
      'erp', p_pedido_id, (d->'destinatario'->>'cliente_id')::uuid, d->'pedido'->>'canal', c.ambiente, 55, c.serie, v_num, c.cnpj, 'processando',
      now(), d->>'natureza_operacao', d->'destinatario'->>'nome', d->'destinatario'->>'documento', d->'destinatario'->>'uf', d->'destinatario'->>'email',
      (d->'totais'->>'produtos')::numeric, (d->'totais'->>'frete')::numeric, (d->'totais'->>'desconto')::numeric, (d->'totais'->>'total')::numeric,
      d, c.provedor, p_usuario)
    returning id into v_id;
    insert into nfe_eventos (nota_id, tipo, sucesso, mensagem, usuario_email)
      values (v_id, 'emissao', null, case when v_num is null then format('Nota registrada (%s, %s) — número será dado pela plataforma.', c.provedor, c.ambiente)
                                          else format('Número %s reservado (série %s, %s).', v_num, c.serie, c.ambiente) end, p_usuario);
  end if;

  return jsonb_build_object('ok', true, 'nota_id', v_id, 'numero', v_num, 'serie', c.serie,
                            'tentativas', (select tentativas from notas_fiscais where id = v_id),
                            'ambiente', c.ambiente, 'provedor', c.provedor, 'dados', d);
end $$;
revoke all on function nfe_registrar_tentativa(uuid, text) from public, anon, authenticated;
grant execute on function nfe_registrar_tentativa(uuid, text) to service_role;

-- 7c) Ajuste manual do "último número usado" (ex: série já usada antes).
--     Nunca deixa voltar para trás de uma nota que já existe.
create or replace function nfe_ajustar_numeracao(p_ambiente text, p_serie int, p_ultimo int)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_max int; v_antes int; v_cnpj text;
begin
  if auth.role() is distinct from 'authenticated' and current_user not in ('postgres', 'service_role') then
    raise exception 'Sem permissão.';
  end if;
  if p_ambiente not in ('simulacao', 'homologacao', 'producao') then raise exception 'Ambiente inválido.'; end if;
  if p_ultimo is null or p_ultimo < 0 or p_ultimo > 999999999 then raise exception 'Número inválido.'; end if;
  select cnpj into v_cnpj from fiscal_config where id = 1;
  select max(numero) into v_max from notas_fiscais
   where origem = 'erp' and ambiente = p_ambiente and serie = p_serie and cnpj_emitente = v_cnpj;
  if p_ultimo < coalesce(v_max, 0) then
    raise exception 'Já existe a nota nº % nesta série — o último número não pode ser menor que isso.', v_max;
  end if;
  select ultimo_numero into v_antes from nfe_numeracao where ambiente = p_ambiente and serie = p_serie;
  insert into nfe_numeracao (ambiente, serie, ultimo_numero) values (p_ambiente, p_serie, p_ultimo)
    on conflict (ambiente, serie) do update set ultimo_numero = excluded.ultimo_numero, updated_at = now();
  insert into nfe_eventos (tipo, sucesso, mensagem, usuario_email)
    values ('numeracao', true, format('Último número da série %s (%s) ajustado de %s para %s.', p_serie, p_ambiente, coalesce(v_antes, 0), p_ultimo),
            coalesce(auth.jwt()->>'email', current_user));
  return jsonb_build_object('ok', true, 'ambiente', p_ambiente, 'serie', p_serie, 'ultimo_numero', p_ultimo, 'proximo', p_ultimo + 1);
end $$;
revoke all on function nfe_ajustar_numeracao(text, int, int) from public, anon;
grant execute on function nfe_ajustar_numeracao(text, int, int) to authenticated, service_role;

-- 7d) Vendas fora do ML que ainda não têm nota viva no ambiente atual.
create or replace function nfe_pedidos_sem_nota(p_dias int default 60)
returns table (id uuid, data_pedido timestamptz, canal text, cliente_nome text, cliente_id uuid,
               valor_total numeric, ultima_nota_status text, ultima_nota_numero int, ultima_nota_motivo text)
language sql stable security invoker set search_path = public as $$
  select p.id, p.data_pedido, p.canal::text, coalesce(cl.nome, p.cliente_nome_avulso), p.cliente_id, p.valor_total,
         ult.status, ult.numero, ult.motivo
    from pedidos_venda p
    left join clientes cl on cl.id = p.cliente_id
    left join lateral (
      select n.status, n.numero, n.motivo from notas_fiscais n
       where n.pedido_id = p.id and n.origem = 'erp' and n.ambiente = (select ambiente from fiscal_config where id = 1)
       order by n.created_at desc limit 1) ult on true
   where p.canal in ('loja_fisica', 'loja_online')
     and p.status = 'confirmado'
     and p.data_pedido >= now() - make_interval(days => greatest(coalesce(p_dias, 60), 1))
     and coalesce(ult.status, 'nenhuma') not in ('processando', 'autorizada', 'cancelando')
   order by p.data_pedido desc
   limit 500
$$;
revoke all on function nfe_pedidos_sem_nota(int) from public, anon;
grant execute on function nfe_pedidos_sem_nota(int) to authenticated, service_role;

-- 7e) Trava: pedido com NF-e de produção viva não pode ser cancelado/excluído;
--     qualquer nota (até simulação) impede excluir o pedido (mensagem clara).
create or replace function pedidos_venda_trava_nfe() returns trigger language plpgsql as $$
declare n record;
begin
  if tg_op = 'UPDATE' then
    if new.status = 'cancelado' and old.status is distinct from 'cancelado' then
      select numero, serie, status into n from notas_fiscais
       where pedido_id = old.id and origem = 'erp' and ambiente = 'producao'
         and status in ('processando', 'autorizada', 'cancelando') limit 1;
      if found then
        raise exception 'Este pedido tem a NF-e nº % (série %) %. Cancele a nota na aba Notas fiscais antes de cancelar o pedido.',
          n.numero, n.serie, n.status;
      end if;
    end if;
    return new;
  else
    select numero, serie, ambiente into n from notas_fiscais where pedido_id = old.id limit 1;
    if found then
      raise exception 'Este pedido tem nota fiscal registrada (nº %, série %, %). Pedido com nota não pode ser excluído%.',
        n.numero, n.serie, n.ambiente,
        case when n.ambiente = 'simulacao' then ' — apague as notas de simulação na aba Notas fiscais e tente de novo' else '' end;
    end if;
    return old;
  end if;
end $$;
create trigger trg_pedidos_venda_trava_nfe
  before update of status or delete on pedidos_venda
  for each row execute function pedidos_venda_trava_nfe();

-- 7g) FILTRO "com NF / sem NF" na lista de vendas.
--     NÃO altera as funções que já existem (_v3, do filtro de envio): cria
--     versões _v4 com um parâmetro a mais (p_nf). p_nf null = igual à _v3.
--     "Com NF" = nota AUTORIZADA (não cancelada) no ambiente atual da
--     configuração, ou nota de marketplace importada (origem 'ml').
create or replace function pedido_tem_nf_autorizada(p_pedido_id uuid)
returns boolean language sql stable security invoker set search_path = public as $$
  select exists (
    select 1 from notas_fiscais n
     where n.pedido_id = p_pedido_id and n.status = 'autorizada'
       and (n.origem = 'ml' or n.ambiente = (select ambiente from fiscal_config where id = 1)))
$$;

create or replace function filtrar_pedidos_venda_v4(p_inicio timestamptz, p_fim timestamptz, p_canal text,
                                                    p_produto uuid, p_texto text, p_modalidade text, p_nf text)
returns setof pedidos_venda language sql stable security invoker set search_path = public as $$
  select f.* from filtrar_pedidos_venda_v3(p_inicio, p_fim, p_canal, p_produto, p_texto, p_modalidade) f
   where p_nf is null
      or (p_nf = 'com' and pedido_tem_nf_autorizada(f.id))
      or (p_nf = 'sem' and not pedido_tem_nf_autorizada(f.id))
$$;

create or replace function listar_pedidos_filtro_ids_v4(p_inicio timestamptz, p_fim timestamptz, p_canal text,
                                                        p_produto uuid, p_texto text, p_modalidade text, p_nf text,
                                                        p_limite int, p_offset int)
returns setof uuid language sql stable security invoker set search_path = public as $$
  select id from filtrar_pedidos_venda_v4(p_inicio, p_fim, p_canal, p_produto, p_texto, p_modalidade, p_nf)
   order by data_pedido desc, id desc
   limit greatest(p_limite, 0) offset greatest(p_offset, 0)
$$;

create or replace function resumo_vendas_filtro_v4(p_inicio timestamptz, p_fim timestamptz, p_canal text,
                                                   p_produto uuid, p_texto text, p_modalidade text, p_nf text)
returns table (total_pedidos bigint, pedidos_confirmados bigint, faturamento numeric)
language sql stable security invoker set search_path = public as $$
  select count(*)::bigint,
         count(*) filter (where status = 'confirmado')::bigint,
         coalesce(sum(valor_total) filter (where status = 'confirmado'), 0)::numeric
    from filtrar_pedidos_venda_v4(p_inicio, p_fim, p_canal, p_produto, p_texto, p_modalidade, p_nf)
$$;

create or replace function resumo_liquido_filtro_v4(p_inicio timestamptz, p_fim timestamptz, p_canal text,
                                                    p_produto uuid, p_texto text, p_modalidade text, p_nf text)
returns table (liquido numeric, pedidos_com_liquido bigint, pedidos_ml_sem_liquido bigint, bruto_dos_com_liquido numeric)
language sql stable security invoker set search_path = public as $$
  select coalesce(sum(valor_liquido) filter (where status = 'confirmado' and valor_liquido is not null), 0)::numeric,
         count(*) filter (where status = 'confirmado' and valor_liquido is not null)::bigint,
         count(*) filter (where status = 'confirmado' and ml_order_id is not null and valor_liquido is null)::bigint,
         coalesce(sum(valor_total) filter (where status = 'confirmado' and valor_liquido is not null), 0)::numeric
    from filtrar_pedidos_venda_v4(p_inicio, p_fim, p_canal, p_produto, p_texto, p_modalidade, p_nf)
$$;
revoke all on function pedido_tem_nf_autorizada(uuid) from public, anon;
revoke all on function filtrar_pedidos_venda_v4(timestamptz, timestamptz, text, uuid, text, text, text) from public, anon;
revoke all on function listar_pedidos_filtro_ids_v4(timestamptz, timestamptz, text, uuid, text, text, text, int, int) from public, anon;
revoke all on function resumo_vendas_filtro_v4(timestamptz, timestamptz, text, uuid, text, text, text) from public, anon;
revoke all on function resumo_liquido_filtro_v4(timestamptz, timestamptz, text, uuid, text, text, text) from public, anon;
grant execute on function pedido_tem_nf_autorizada(uuid) to authenticated, service_role;
grant execute on function filtrar_pedidos_venda_v4(timestamptz, timestamptz, text, uuid, text, text, text) to authenticated, service_role;
grant execute on function listar_pedidos_filtro_ids_v4(timestamptz, timestamptz, text, uuid, text, text, text, int, int) to authenticated, service_role;
grant execute on function resumo_vendas_filtro_v4(timestamptz, timestamptz, text, uuid, text, text, text) to authenticated, service_role;
grant execute on function resumo_liquido_filtro_v4(timestamptz, timestamptz, text, uuid, text, text, text) to authenticated, service_role;

-- conferência: sem p_nf, as _v4 dão EXATAMENTE o mesmo que as _v3
do $$
declare c record; a jsonb; b jsonb;
begin
  for c in select * from (values
      (null::timestamptz, null::timestamptz, null::text, null::text, null::text),
      (now() - interval '30 days', now(), null, null, null),
      (now() - interval '365 days', now(), 'loja_fisica', null, null),
      (now() - interval '90 days', now(), 'ml_conta1', 'rolo', null),
      (null, null, 'ml_conta3', null, 'full'),
      (now() - interval '60 days', null, null, null, 'flex'),
      (now() - interval '7 days', null, null, 'tekbond', null)) v(i, f, cn, tx, md)
  loop
    select to_jsonb(r) into a from resumo_vendas_filtro_v3(c.i, c.f, c.cn, null, c.tx, c.md) r;
    select to_jsonb(r) into b from resumo_vendas_filtro_v4(c.i, c.f, c.cn, null, c.tx, c.md, null) r;
    if a is distinct from b then raise exception 'PARADO: resumo _v4 diverge da _v3 (% vs %).', a, b; end if;
    select to_jsonb(r) into a from resumo_liquido_filtro_v3(c.i, c.f, c.cn, null, c.tx, c.md) r;
    select to_jsonb(r) into b from resumo_liquido_filtro_v4(c.i, c.f, c.cn, null, c.tx, c.md, null) r;
    if a is distinct from b then raise exception 'PARADO: líquido _v4 diverge da _v3.'; end if;
    select jsonb_agg(x) into a from listar_pedidos_filtro_ids_v3(c.i, c.f, c.cn, null, c.tx, c.md, 100, 0) x;
    select jsonb_agg(x) into b from listar_pedidos_filtro_ids_v4(c.i, c.f, c.cn, null, c.tx, c.md, null, 100, 0) x;
    if a is distinct from b then raise exception 'PARADO: lista _v4 diverge da _v3.'; end if;
  end loop;
end $$;

-- 7f) Apagar notas de SIMULAÇÃO (só elas). Os arquivos no bucket são
--     apagados pela Edge Function antes de chamar esta função.
create or replace function nfe_limpar_simulacao()
returns int language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  delete from notas_fiscais where ambiente = 'simulacao';
  get diagnostics n = row_count;
  update nfe_numeracao set ultimo_numero = 0, updated_at = now() where ambiente = 'simulacao';
  return n;
end $$;
revoke all on function nfe_limpar_simulacao() from public, anon, authenticated;
grant execute on function nfe_limpar_simulacao() to service_role;

-- ============================================================
-- 8) TESTE COMPLETO (tudo desfeito no fim)
-- ============================================================
do $$
declare
  v_cli uuid; v_ped uuid; v_prod uuid; r jsonb; r2 jsonb; n1 int; n2 int; v_nota uuid; msg text;
begin
  begin
    -- empresa completa (só dentro do teste)
    update fiscal_config set ie = '123456789012', logradouro = 'Rua Teste', numero = '1', bairro = 'Centro',
           cep = '14000000' where id = 1;
    select id into v_prod from produtos where tipo = 'produto_acabado' and ativo order by sku_interno limit 1;
    update produtos set ncm = '4819.10.00', cfop_dentro_sp = '5102', csosn = '102' where id = v_prod;

    insert into clientes (nome, documento, email, logradouro, numero, bairro, cep, municipio, codigo_municipio, uf, indicador_ie)
    values ('CLIENTE TESTE LOTE 9', '11.222.333/0001-81', 't@t.com', 'Av Teste', '10', 'Centro', '01001-000', 'São Paulo', '3550308', 'sp', 9)
    returning id into v_cli;
    if (select documento from clientes where id = v_cli) <> '11222333000181' or (select uf from clientes where id = v_cli) <> 'SP'
       or (select tipo_pessoa from clientes where id = v_cli) <> 'J' then
      raise exception 'PARADO: normalização do cliente errada.';
    end if;

    v_ped := criar_pedido_venda('loja_fisica', 'TESTE LOTE 9', 'fisico', now(), 10, 2, 0, null,
              jsonb_build_array(jsonb_build_object('produto_id', v_prod, 'quantidade', 3, 'preco_unitario', 10.01)));

    -- sem cliente → pendência
    r := nfe_preparar(v_ped);
    if (r->>'ok')::boolean or not (r->'pendencias')::text like '%Escolha o cliente%' then
      raise exception 'PARADO: pendência de cliente não apareceu: %', r;
    end if;

    update pedidos_venda set cliente_id = v_cli where id = v_ped;
    r := nfe_preparar(v_ped);
    if not (r->>'ok')::boolean then raise exception 'PARADO: preparar deveria passar: %', r->'pendencias'; end if;
    if (r->'dados'->'totais'->>'total')::numeric <> 38.03 then raise exception 'PARADO: total errado %', r->'dados'->'totais'; end if;
    if (r->'dados'->'itens'->0->>'ncm') <> '48191000' or (r->'dados'->'itens'->0->>'cfop') <> '5102'
       or (r->'dados'->'itens'->0->>'valor_frete')::numeric <> 10 or (r->'dados'->'itens'->0->>'valor_desconto')::numeric <> 2
       or (r->'dados'->'itens'->0->>'cst_pis') <> '99' or (r->'dados'->'itens'->0->>'cst_cofins') <> '99' then
      raise exception 'PARADO: item montado errado %', r->'dados'->'itens';
    end if;

    -- 1ª emissão: número 1
    r := nfe_registrar_tentativa(v_ped, 'teste');
    n1 := (r->>'numero')::int; v_nota := (r->>'nota_id')::uuid;
    if n1 <> 1 then raise exception 'PARADO: primeiro número deveria ser 1, veio %', n1; end if;

    -- 2º clique com a nota processando → recusado
    r2 := nfe_registrar_tentativa(v_ped, 'teste');
    if (r2->>'ok')::boolean then raise exception 'PARADO: deixou emitir 2 notas do mesmo pedido.'; end if;

    -- rejeitada → nova tentativa reaproveita o MESMO número
    update notas_fiscais set status = 'rejeitada', motivo = 'teste' where id = v_nota;
    r2 := nfe_registrar_tentativa(v_ped, 'teste');
    if (r2->>'numero')::int <> n1 or (r2->>'nota_id')::uuid <> v_nota then
      raise exception 'PARADO: rejeitada não reaproveitou o número (%).', r2;
    end if;

    -- autorizada → cancelada → nova nota pega o próximo número (+1)
    update notas_fiscais set status = 'cancelada' where id = v_nota;
    r2 := nfe_registrar_tentativa(v_ped, 'teste');
    n2 := (r2->>'numero')::int;
    if n2 <> n1 + 1 then raise exception 'PARADO: próximo número deveria ser %, veio %', n1 + 1, n2; end if;

    -- ajuste de numeração não deixa voltar para trás
    begin
      perform nfe_ajustar_numeracao('simulacao', 3, 1);
      raise exception 'PARADO: deixou voltar a numeração.';
    exception when raise_exception then
      if sqlerrm like 'PARADO%' then raise; end if;
    end;
    perform nfe_ajustar_numeracao('simulacao', 3, 10);
    if (select ultimo_numero from nfe_numeracao where ambiente = 'simulacao' and serie = 3) <> 10 then
      raise exception 'PARADO: ajuste de numeração não gravou.';
    end if;

    -- trava de cancelamento só com nota de PRODUÇÃO viva
    update notas_fiscais set status = 'autorizada' where id = (r2->>'nota_id')::uuid;
    -- filtro "com NF": pedido aparece; "sem NF": não aparece
    if not exists (select 1 from filtrar_pedidos_venda_v4(null, null, 'loja_fisica', null, null, null, 'com') f where f.id = v_ped)
       or exists (select 1 from filtrar_pedidos_venda_v4(null, null, 'loja_fisica', null, null, null, 'sem') f where f.id = v_ped) then
      raise exception 'PARADO: filtro com/sem NF errado.';
    end if;
    -- consumidor final vem do cadastro (contribuinte que compra para revenda → 0)
    update clientes set indicador_ie = 1, ie = '123456789012', consumidor_final = false where id = v_cli;
    update notas_fiscais set status = 'cancelada' where id = (r2->>'nota_id')::uuid;
    r := nfe_preparar(v_ped);
    if (r->'dados'->>'consumidor_final')::int <> 0 then raise exception 'PARADO: consumidor final não respeitou o cadastro.'; end if;
    update notas_fiscais set status = 'autorizada' where id = (r2->>'nota_id')::uuid;
    update pedidos_venda set status = 'confirmado' where id = v_ped;  -- não dispara (não é cancelamento)
    update notas_fiscais set ambiente = 'producao' where id = (r2->>'nota_id')::uuid;
    begin
      perform cancelar_pedido_venda(v_ped);
      raise exception 'PARADO: cancelou pedido com NF-e de produção autorizada.';
    exception when raise_exception then
      if sqlerrm like 'PARADO%' then raise; end if;
      if sqlerrm not like '%Cancele a nota%' then raise exception 'PARADO: mensagem inesperada: %', sqlerrm; end if;
    end;
    -- exclusão bloqueada com mensagem clara
    begin
      perform excluir_pedido_venda(v_ped);
      raise exception 'PARADO: excluiu pedido com nota.';
    exception when raise_exception then
      if sqlerrm like 'PARADO%' then raise; end if;
    end;

    -- SysVelox (homologação): o ERP NÃO reserva número; a plataforma numera
    update notas_fiscais set status = 'cancelada', ambiente = 'simulacao' where id = (r2->>'nota_id')::uuid;
    update fiscal_config set ambiente = 'homologacao', provedor = 'sysvelox' where id = 1;
    r2 := nfe_registrar_tentativa(v_ped, 'teste');
    if not (r2->>'ok')::boolean or (r2->>'numero') is not null then raise exception 'PARADO: SysVelox não deveria reservar número (%).', r2; end if;
    update notas_fiscais set status = 'autorizada', numero = 1, serie = 3 where id = (r2->>'nota_id')::uuid;
    -- fração de centavo no preço vira pendência
    update pedido_itens set subtotal = 30.04 where pedido_id = v_ped;  -- preco_unitario é numeric(14,2): fração de centavo é impossível; testa o subtotal que não fecha
    update notas_fiscais set status = 'cancelada' where id = (r2->>'nota_id')::uuid;
    r := nfe_preparar(v_ped);
    if (r->'pendencias')::text not like '%não fecha com o subtotal%' then raise exception 'PARADO: subtotal divergente não virou pendência.'; end if;

    raise exception 'TESTE_OK';
  exception when raise_exception then
    if sqlerrm <> 'TESTE_OK' then raise; end if;
  end;
end $$;

-- ---------- conferência final: nada do resto mudou ----------
do $$
declare a record;
begin
  select * into a from _antes;
  if a.fat <> (select coalesce(sum(valor_total) filter (where status = 'confirmado'), 0) from pedidos_venda)
     or a.n_ped <> (select count(*) from pedidos_venda)
     or a.estoque <> (select coalesce(sum(quantidade), 0) from estoque_saldos)
     or a.n_mov <> (select count(*) from movimentacoes_estoque)
     or a.n_lanc <> (select count(*) from lancamentos_financeiros)
     or a.n_prod <> (select count(*) from produtos)
     or a.fiscal_prod <> (select md5(string_agg(id || coalesce(ncm,'') || coalesce(cest,'') || coalesce(csosn,'') || coalesce(cfop_dentro_sp,'') || coalesce(cfop_fora_sp,''), ',' order by id)) from produtos)
     or (select count(*) from clientes) <> 0
     or (select count(*) from notas_fiscais) <> 0
     or (select sum(ultimo_numero) from nfe_numeracao) <> 0 then
    raise exception 'PARADO: algo fora do módulo fiscal mudou (ou o teste deixou resto). Nada foi aplicado.';
  end if;
end $$;

commit;

select 'ok — estrutura da NF-e pronta; teste de numeração passou; faturamento/estoque iguais' as status,
       (select ambiente || ' / série ' || serie || ' / ' || provedor from fiscal_config) as configuracao,
       (select string_agg(ambiente || ': próximo nº ' || (ultimo_numero + 1), ', ' order by ambiente) from nfe_numeracao) as numeracao;
