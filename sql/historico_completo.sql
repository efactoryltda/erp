-- ============================================================
-- ERP E-Factory — HISTÓRICO COMPLETO DE SQL
-- Este arquivo é só um REGISTRO — os comandos abaixo já foram
-- aplicados no banco, na ordem que aparecem. Não precisa rodar
-- de novo. Serve só pra não perder o histórico do que foi feito.
-- ============================================================


-- ================================================================
-- ARQUIVO ORIGINAL: 001_fundacao.sql
-- ================================================================
-- ============================================================
-- ERP E-Factory — FUNDAÇÃO
-- Produtos | Ficha Técnica (BOM) | Estoque | Produção
-- Cole este arquivo inteiro no Supabase SQL Editor e clique em RUN.
-- ============================================================

-- ---------- TIPOS ----------

create type tipo_produto as enum ('materia_prima', 'produto_acabado');

create type local_estoque as enum ('materia_prima', 'fisico', 'full');

create type tipo_movimento_estoque as enum (
  'entrada_manual',
  'saida_manual',
  'ajuste',
  'transferencia',
  'producao_consumo',
  'producao_entrada',
  'venda',
  'devolucao'
);

create type status_ordem_producao as enum ('rascunho', 'em_producao', 'concluida', 'cancelada');


-- ---------- PRODUTOS ----------
-- Cadastro único para matéria-prima E produto acabado (o campo "tipo" diferencia).

create table produtos (
  id uuid primary key default gen_random_uuid(),
  sku_interno text unique not null,
  nome text not null,
  descricao text,
  tipo tipo_produto not null,
  categoria text,
  ncm text,
  cest text,
  unidade_medida text not null,            -- ex: UN, KG, M, RL
  peso_kg numeric(12,3),
  custo_atual numeric(14,4) default 0,     -- custo médio, atualizado pela produção
  preco_venda numeric(14,2),               -- só se aplica a produto_acabado
  estoque_minimo numeric(14,3) default 0,
  estoque_maximo numeric(14,3),
  ativo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);


-- ---------- FICHA TÉCNICA (BOM) ----------
-- Diz quanto de cada matéria-prima é gasto para produzir 1 unidade de um produto acabado.

create table ficha_tecnica_itens (
  id uuid primary key default gen_random_uuid(),
  produto_acabado_id uuid not null references produtos(id),
  produto_materia_prima_id uuid not null references produtos(id),
  quantidade_necessaria numeric(14,6) not null,   -- por 1 unidade do produto acabado
  created_at timestamptz not null default now(),
  constraint chk_produto_acabado_diferente check (produto_acabado_id <> produto_materia_prima_id)
);


-- ---------- ESTOQUE (saldo atual por produto e por local) ----------
-- "local" separa matéria-prima / estoque físico (depósito) / estoque Full (dentro do ML)

create table estoque_saldos (
  id uuid primary key default gen_random_uuid(),
  produto_id uuid not null references produtos(id),
  local local_estoque not null,
  quantidade numeric(14,3) not null default 0,
  quantidade_reservada numeric(14,3) not null default 0,
  updated_at timestamptz not null default now(),
  unique (produto_id, local)
);


-- ---------- MOVIMENTAÇÕES DE ESTOQUE (histórico/auditoria) ----------
-- Todo evento que mexe em estoque gera uma linha aqui. Isso é o que garante rastreabilidade.

create table movimentacoes_estoque (
  id uuid primary key default gen_random_uuid(),
  produto_id uuid not null references produtos(id),
  local local_estoque not null,
  tipo_movimento tipo_movimento_estoque not null,
  quantidade numeric(14,3) not null,     -- positivo = entrada, negativo = saída
  referencia_tipo text,                  -- ex: 'ordem_producao', 'venda_ml', 'venda_pdv'
  referencia_id uuid,
  observacao text,
  created_at timestamptz not null default now()
);


-- ---------- ORDENS DE PRODUÇÃO ----------

create table ordens_producao (
  id uuid primary key default gen_random_uuid(),
  produto_acabado_id uuid not null references produtos(id),
  quantidade_planejada numeric(14,3) not null,
  quantidade_produzida numeric(14,3) default 0,
  status status_ordem_producao not null default 'rascunho',
  custo_producao_total numeric(14,4),
  data_abertura timestamptz not null default now(),
  data_conclusao timestamptz,
  observacao text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);


-- ---------- ÍNDICES ----------

create index idx_produtos_tipo on produtos(tipo);
create index idx_estoque_produto on estoque_saldos(produto_id);
create index idx_movimentacoes_produto on movimentacoes_estoque(produto_id);
create index idx_ficha_tecnica_produto_acabado on ficha_tecnica_itens(produto_acabado_id);


-- ---------- SEGURANÇA (RLS) ----------
-- Libera acesso total só pra usuários logados. Sem isso, qualquer pessoa com o link
-- do seu Supabase conseguiria ler/editar os dados. Vamos configurar o login em seguida.

alter table produtos enable row level security;
alter table ficha_tecnica_itens enable row level security;
alter table estoque_saldos enable row level security;
alter table movimentacoes_estoque enable row level security;
alter table ordens_producao enable row level security;

create policy "authenticated_all_produtos" on produtos for all to authenticated using (true) with check (true);
create policy "authenticated_all_ficha_tecnica" on ficha_tecnica_itens for all to authenticated using (true) with check (true);
create policy "authenticated_all_estoque" on estoque_saldos for all to authenticated using (true) with check (true);
create policy "authenticated_all_movimentacoes" on movimentacoes_estoque for all to authenticated using (true) with check (true);
create policy "authenticated_all_ordens_producao" on ordens_producao for all to authenticated using (true) with check (true);


-- ================================================================
-- ARQUIVO ORIGINAL: 002_funcoes.sql
-- ================================================================
-- ============================================================
-- ERP E-Factory — FUNÇÕES E AJUSTE DE ACESSO
-- Cole no SQL Editor do Supabase DEPOIS de rodar o arquivo da fundação.
-- ============================================================

-- ---------- ACESSO TEMPORÁRIO SEM LOGIN ----------
-- Como ainda não existe tela de login no sistema, liberamos o acesso
-- também para o modo "anon" (sem login). Isso é aceitável enquanto só
-- você usa o sistema e não compartilha o link publicamente. Quando
-- outras pessoas precisarem acessar, criamos um login de verdade.

drop policy if exists "authenticated_all_produtos" on produtos;
create policy "acesso_produtos" on produtos for all to authenticated, anon using (true) with check (true);

drop policy if exists "authenticated_all_ficha_tecnica" on ficha_tecnica_itens;
create policy "acesso_ficha_tecnica" on ficha_tecnica_itens for all to authenticated, anon using (true) with check (true);

drop policy if exists "authenticated_all_estoque" on estoque_saldos;
create policy "acesso_estoque" on estoque_saldos for all to authenticated, anon using (true) with check (true);

drop policy if exists "authenticated_all_movimentacoes" on movimentacoes_estoque;
create policy "acesso_movimentacoes" on movimentacoes_estoque for all to authenticated, anon using (true) with check (true);

drop policy if exists "authenticated_all_ordens_producao" on ordens_producao;
create policy "acesso_ordens_producao" on ordens_producao for all to authenticated, anon using (true) with check (true);


-- ---------- FUNÇÃO: CONCLUIR ORDEM DE PRODUÇÃO ----------
-- Quando uma ordem de produção é concluída, esta função faz tudo de uma vez,
-- de forma segura (ou tudo acontece, ou nada acontece — sem risco de ficar
-- pela metade):
--   1. Consulta a ficha técnica do produto acabado
--   2. Baixa a quantidade correspondente de cada matéria-prima do estoque
--   3. Lança o produto acabado no estoque físico
--   4. Calcula o custo de produção com base no custo das matérias-primas usadas
--   5. Marca a ordem como concluída

create or replace function concluir_ordem_producao(
  p_ordem_id uuid,
  p_quantidade_produzida numeric
)
returns void
language plpgsql
security definer
as $$
declare
  v_produto_acabado_id uuid;
  v_custo_total numeric := 0;
  v_custo_unitario numeric;
  item record;
begin
  select produto_acabado_id into v_produto_acabado_id
  from ordens_producao
  where id = p_ordem_id;

  if v_produto_acabado_id is null then
    raise exception 'Ordem de produção não encontrada';
  end if;

  -- consome cada matéria-prima da ficha técnica
  for item in
    select produto_materia_prima_id, quantidade_necessaria
    from ficha_tecnica_itens
    where produto_acabado_id = v_produto_acabado_id
  loop
    select custo_atual into v_custo_unitario
    from produtos where id = item.produto_materia_prima_id;

    v_custo_total := v_custo_total
      + (item.quantidade_necessaria * p_quantidade_produzida * coalesce(v_custo_unitario, 0));

    update estoque_saldos
      set quantidade = quantidade - (item.quantidade_necessaria * p_quantidade_produzida),
          updated_at = now()
      where produto_id = item.produto_materia_prima_id and local = 'materia_prima';

    insert into movimentacoes_estoque
      (produto_id, local, tipo_movimento, quantidade, referencia_tipo, referencia_id)
    values
      (item.produto_materia_prima_id, 'materia_prima', 'producao_consumo',
       -(item.quantidade_necessaria * p_quantidade_produzida), 'ordem_producao', p_ordem_id);
  end loop;

  -- lança o produto acabado no estoque físico
  insert into estoque_saldos (produto_id, local, quantidade)
  values (v_produto_acabado_id, 'fisico', p_quantidade_produzida)
  on conflict (produto_id, local) do update
    set quantidade = estoque_saldos.quantidade + p_quantidade_produzida,
        updated_at = now();

  insert into movimentacoes_estoque
    (produto_id, local, tipo_movimento, quantidade, referencia_tipo, referencia_id)
  values
    (v_produto_acabado_id, 'fisico', 'producao_entrada', p_quantidade_produzida, 'ordem_producao', p_ordem_id);

  -- atualiza o custo do produto acabado
  update produtos
    set custo_atual = v_custo_total / nullif(p_quantidade_produzida, 0),
        updated_at = now()
    where id = v_produto_acabado_id;

  -- marca a ordem como concluída
  update ordens_producao
    set status = 'concluida',
        quantidade_produzida = p_quantidade_produzida,
        custo_producao_total = v_custo_total,
        data_conclusao = now(),
        updated_at = now()
    where id = p_ordem_id;
end;
$$;

grant execute on function concluir_ordem_producao(uuid, numeric) to anon, authenticated;


-- ================================================================
-- ARQUIVO ORIGINAL: 003_vendas.sql
-- ================================================================
-- ============================================================
-- ERP E-Factory — VENDAS
-- Cole no SQL Editor do Supabase DEPOIS de rodar fundação + funções.
-- ============================================================

-- ---------- TIPOS ----------

create type canal_venda as enum ('ml_conta1', 'ml_conta2', 'ml_conta3', 'loja_fisica');
create type status_pedido as enum ('confirmado', 'cancelado');

alter type tipo_movimento_estoque add value if not exists 'cancelamento_venda';


-- ---------- CLIENTES ----------

create table clientes (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  documento text,
  telefone text,
  email text,
  endereco text,
  created_at timestamptz not null default now()
);


-- ---------- PEDIDOS DE VENDA ----------

create table pedidos_venda (
  id uuid primary key default gen_random_uuid(),
  numero_pedido text,
  canal canal_venda not null,
  cliente_id uuid references clientes(id),
  cliente_nome_avulso text,
  local_baixa_estoque local_estoque not null default 'fisico',
  data_pedido timestamptz not null default now(),
  status status_pedido not null default 'confirmado',
  valor_produtos numeric(14,2) not null default 0,
  valor_frete numeric(14,2) not null default 0,
  desconto numeric(14,2) not null default 0,
  taxas_canal numeric(14,2) not null default 0,
  valor_total numeric(14,2) not null default 0,
  observacao text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table pedido_itens (
  id uuid primary key default gen_random_uuid(),
  pedido_id uuid not null references pedidos_venda(id) on delete cascade,
  produto_id uuid not null references produtos(id),
  quantidade numeric(14,3) not null,
  preco_unitario numeric(14,2) not null,
  subtotal numeric(14,2) not null
);

create index idx_pedidos_data on pedidos_venda(data_pedido);
create index idx_pedidos_canal on pedidos_venda(canal);
create index idx_pedidos_status on pedidos_venda(status);
create index idx_pedido_itens_pedido on pedido_itens(pedido_id);


-- ---------- SEGURANÇA (mesma regra temporária das outras tabelas) ----------

alter table clientes enable row level security;
alter table pedidos_venda enable row level security;
alter table pedido_itens enable row level security;

create policy "acesso_clientes" on clientes for all to authenticated, anon using (true) with check (true);
create policy "acesso_pedidos_venda" on pedidos_venda for all to authenticated, anon using (true) with check (true);
create policy "acesso_pedido_itens" on pedido_itens for all to authenticated, anon using (true) with check (true);


-- ---------- FUNÇÃO: CRIAR PEDIDO DE VENDA ----------
-- Recebe o cabeçalho do pedido + uma lista de itens (em formato jsonb) e faz tudo de uma vez:
--   1. Calcula o valor total dos produtos
--   2. Grava o pedido e os itens
--   3. Baixa o estoque de cada item (do local indicado: físico ou Full)
--   4. Registra a movimentação de estoque

create or replace function criar_pedido_venda(
  p_canal canal_venda,
  p_cliente_nome text,
  p_local_baixa_estoque local_estoque,
  p_data_pedido timestamptz,
  p_valor_frete numeric,
  p_desconto numeric,
  p_taxas_canal numeric,
  p_observacao text,
  p_itens jsonb
)
returns uuid
language plpgsql
security definer
as $$
declare
  v_pedido_id uuid;
  v_valor_produtos numeric := 0;
  v_valor_total numeric;
  item jsonb;
  v_produto_id uuid;
  v_quantidade numeric;
  v_preco numeric;
begin
  for item in select * from jsonb_array_elements(p_itens)
  loop
    v_valor_produtos := v_valor_produtos + ((item->>'quantidade')::numeric * (item->>'preco_unitario')::numeric);
  end loop;

  v_valor_total := v_valor_produtos + coalesce(p_valor_frete,0) - coalesce(p_desconto,0);

  insert into pedidos_venda
    (canal, cliente_nome_avulso, local_baixa_estoque, data_pedido, status,
     valor_produtos, valor_frete, desconto, taxas_canal, valor_total, observacao)
  values
    (p_canal, p_cliente_nome, p_local_baixa_estoque, coalesce(p_data_pedido, now()), 'confirmado',
     v_valor_produtos, coalesce(p_valor_frete,0), coalesce(p_desconto,0), coalesce(p_taxas_canal,0), v_valor_total, p_observacao)
  returning id into v_pedido_id;

  for item in select * from jsonb_array_elements(p_itens)
  loop
    v_produto_id := (item->>'produto_id')::uuid;
    v_quantidade := (item->>'quantidade')::numeric;
    v_preco := (item->>'preco_unitario')::numeric;

    insert into pedido_itens (pedido_id, produto_id, quantidade, preco_unitario, subtotal)
    values (v_pedido_id, v_produto_id, v_quantidade, v_preco, v_quantidade * v_preco);

    update estoque_saldos
      set quantidade = quantidade - v_quantidade, updated_at = now()
      where produto_id = v_produto_id and local = p_local_baixa_estoque;

    insert into movimentacoes_estoque (produto_id, local, tipo_movimento, quantidade, referencia_tipo, referencia_id)
    values (v_produto_id, p_local_baixa_estoque, 'venda', -v_quantidade, 'pedido_venda', v_pedido_id);
  end loop;

  return v_pedido_id;
end;
$$;

grant execute on function criar_pedido_venda(canal_venda, text, local_estoque, timestamptz, numeric, numeric, numeric, text, jsonb) to anon, authenticated;


-- ---------- FUNÇÃO: CANCELAR PEDIDO DE VENDA ----------
-- Devolve o estoque de cada item pro local de onde ele saiu, e marca o pedido como cancelado.

create or replace function cancelar_pedido_venda(p_pedido_id uuid)
returns void
language plpgsql
security definer
as $$
declare
  item record;
  v_local local_estoque;
  v_status status_pedido;
begin
  select status, local_baixa_estoque into v_status, v_local from pedidos_venda where id = p_pedido_id;

  if v_status is null then
    raise exception 'Pedido não encontrado';
  end if;

  if v_status = 'cancelado' then
    raise exception 'Pedido já está cancelado';
  end if;

  for item in select produto_id, quantidade from pedido_itens where pedido_id = p_pedido_id
  loop
    update estoque_saldos
      set quantidade = quantidade + item.quantidade, updated_at = now()
      where produto_id = item.produto_id and local = v_local;

    insert into movimentacoes_estoque (produto_id, local, tipo_movimento, quantidade, referencia_tipo, referencia_id)
    values (item.produto_id, v_local, 'cancelamento_venda', item.quantidade, 'pedido_venda', p_pedido_id);
  end loop;

  update pedidos_venda set status = 'cancelado', updated_at = now() where id = p_pedido_id;
end;
$$;

grant execute on function cancelar_pedido_venda(uuid) to anon, authenticated;


-- ================================================================
-- ARQUIVO ORIGINAL: 004_full_multiplo.sql
-- ================================================================
-- ============================================================
-- ERP E-Factory — FULL POR CONTA
-- Cole no SQL Editor DEPOIS de já ter rodado fundação + funções + vendas.
-- ============================================================

-- Adiciona 3 novos locais de estoque, um por conta do Mercado Livre.
-- O valor antigo "full" (genérico) continua existindo no banco por
-- segurança, mas a partir de agora usamos só os três novos.

alter type local_estoque add value if not exists 'full_conta1';
alter type local_estoque add value if not exists 'full_conta2';
alter type local_estoque add value if not exists 'full_conta3';


-- ================================================================
-- ARQUIVO ORIGINAL: 005_excluir_produto_v1.sql
-- ================================================================
-- ============================================================
-- ERP E-Factory — EXCLUSÃO COMPLETA DE PRODUTO
-- Cole no SQL Editor.
-- ============================================================

create or replace function excluir_produto(p_produto_id uuid)
returns void
language plpgsql
security definer
as $$
begin
  if exists (select 1 from pedido_itens where produto_id = p_produto_id) then
    raise exception 'Este produto está em pedidos de venda registrados. Exclua ou edite esses pedidos primeiro.';
  end if;

  if exists (select 1 from ordens_producao where produto_acabado_id = p_produto_id) then
    raise exception 'Este produto está em ordens de produção registradas. Exclua essas ordens primeiro.';
  end if;

  delete from movimentacoes_estoque where produto_id = p_produto_id;
  delete from estoque_saldos where produto_id = p_produto_id;
  delete from ficha_tecnica_itens where produto_acabado_id = p_produto_id or produto_materia_prima_id = p_produto_id;
  delete from produtos where id = p_produto_id;
end;
$$;

grant execute on function excluir_produto(uuid) to anon, authenticated;


-- ================================================================
-- ARQUIVO ORIGINAL: 006_integracao_ml.sql
-- ================================================================
-- ============================================================
-- ERP E-Factory — INTEGRAÇÃO MERCADO LIVRE (estrutura)
-- Cole no SQL Editor DEPOIS de fundação + funções + vendas + full múltiplo.
-- ============================================================

-- ---------- TABELA DE CONEXÕES (uma linha por conta ML) ----------
-- IMPORTANTE: essa tabela guarda tokens de acesso — informação sensível.
-- Diferente das outras tabelas do sistema, ela NÃO recebe policy de acesso
-- livre (nem anon, nem authenticated). Só as funções de servidor (que usam
-- a chave "service role", que ignora RLS) conseguem ler e escrever aqui.
-- Isso impede que alguém com a chave pública do site consiga ver os tokens.

create table integracoes_ml (
  id uuid primary key default gen_random_uuid(),
  canal canal_venda not null unique,
  ml_user_id text,
  access_token text,
  refresh_token text,
  expires_at timestamptz,
  conectado_em timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table integracoes_ml enable row level security;
-- Nenhuma policy criada de propósito — acesso bloqueado por padrão pra anon/authenticated.

alter table integracoes_ml add column if not exists ml_nickname text;



-- ---------- FUNÇÃO SEGURA PRA MOSTRAR STATUS (sem expor tokens) ----------
-- O app usa essa função pra saber quais contas estão conectadas,
-- sem nunca ter acesso aos tokens de verdade.

create or replace function listar_integracoes_ml()
returns table (canal canal_venda, ml_user_id text, conectado_em timestamptz)
language sql
security definer
as $$
  select canal, ml_user_id, conectado_em from integracoes_ml;
$$;

grant execute on function listar_integracoes_ml() to anon, authenticated;


-- ---------- AJUSTES EM TABELAS EXISTENTES ----------

-- Campo pra mapear o SKU que você usa no anúncio do Mercado Livre,
-- caso seja diferente do SKU interno. Se deixar em branco, o sistema
-- tenta casar pelo SKU interno mesmo.
alter table produtos add column if not exists sku_ml text;
create index if not exists idx_produtos_sku_ml on produtos(sku_ml);

-- Guarda o ID do pedido no Mercado Livre, pra nunca importar o mesmo pedido duas vezes.
alter table pedidos_venda add column if not exists ml_order_id text unique;

-- Permite registrar um item de pedido mesmo quando o sistema não conseguiu
-- identificar automaticamente qual produto cadastrado ele corresponde
-- (fica registrado o SKU recebido do Mercado Livre pra você revisar depois).
alter table pedido_itens alter column produto_id drop not null;
alter table pedido_itens add column if not exists sku_ml_item text;


-- ================================================================
-- ARQUIVO ORIGINAL: 007_integracao_ml_nickname.sql
-- ================================================================
-- ============================================================
-- ERP E-Factory — INCREMENTO: apelido da conta ML
-- Cole no SQL Editor. Só adiciona uma coluna e atualiza uma função —
-- seguro rodar mesmo já tendo rodado o schema_integracao_ml antes.
-- ============================================================

alter table integracoes_ml add column if not exists ml_nickname text;

drop function if exists listar_integracoes_ml();

create or replace function listar_integracoes_ml()
returns table (canal canal_venda, ml_user_id text, ml_nickname text, conectado_em timestamptz)
language sql
security definer
as $$
  select canal, ml_user_id, ml_nickname, conectado_em from integracoes_ml;
$$;

grant execute on function listar_integracoes_ml() to anon, authenticated;


-- ================================================================
-- ARQUIVO ORIGINAL: 008_exclusoes_definitivo.sql
-- ================================================================
-- ============================================================
-- ERP E-Factory — EXCLUSÕES (versão definitiva)
-- Cole no SQL Editor. Substitui a função excluir_produto anterior
-- e adiciona a exclusão de pedido de venda.
-- ============================================================

-- ---------- EXCLUIR PRODUTO (revisada) ----------
-- Regras:
--  - Bloqueia se o produto está em algum PEDIDO DE VENDA (exclua o pedido primeiro).
--  - Bloqueia se o produto está em alguma ORDEM DE PRODUÇÃO (exclua a ordem primeiro).
--  - Bloqueia se o produto é usado como MATÉRIA-PRIMA na ficha técnica de OUTRO
--    produto (avisa qual produto usa, pra você remover essa relação primeiro).
--  - Se nada disso existir, apaga em cascata: movimentações de estoque, saldo de
--    estoque, a própria ficha técnica dele (como produto acabado), e o produto.

create or replace function excluir_produto(p_produto_id uuid)
returns void
language plpgsql
security definer
as $$
declare
  v_usado_como_ingrediente_em text;
begin
  if exists (select 1 from pedido_itens where produto_id = p_produto_id) then
    raise exception 'Este produto está em pedidos de venda registrados. Exclua esses pedidos primeiro (aba Vendas).';
  end if;

  if exists (select 1 from ordens_producao where produto_acabado_id = p_produto_id) then
    raise exception 'Este produto está em ordens de produção registradas. Exclua essas ordens primeiro (aba Produção).';
  end if;

  select string_agg(distinct p.nome, ', ')
    into v_usado_como_ingrediente_em
    from ficha_tecnica_itens fti
    join produtos p on p.id = fti.produto_acabado_id
    where fti.produto_materia_prima_id = p_produto_id;

  if v_usado_como_ingrediente_em is not null then
    raise exception 'Este produto é usado como matéria-prima na ficha técnica de: %. Remova essa relação primeiro (aba Ficha Técnica).', v_usado_como_ingrediente_em;
  end if;

  delete from movimentacoes_estoque where produto_id = p_produto_id;
  delete from estoque_saldos where produto_id = p_produto_id;
  delete from ficha_tecnica_itens where produto_acabado_id = p_produto_id;
  delete from produtos where id = p_produto_id;
end;
$$;

grant execute on function excluir_produto(uuid) to anon, authenticated;


-- ---------- EXCLUIR PEDIDO DE VENDA (novo) ----------
-- Diferente de "Cancelar" (que mantém o registro marcado como cancelado),
-- isso apaga o pedido de verdade. Se o pedido ainda estava confirmado,
-- devolve o estoque antes de apagar. Os itens do pedido são apagados
-- automaticamente junto (relação em cascata já configurada).

create or replace function excluir_pedido_venda(p_pedido_id uuid)
returns void
language plpgsql
security definer
as $$
declare
  item record;
  v_status status_pedido;
  v_local local_estoque;
  v_saldo_id uuid;
begin
  select status, local_baixa_estoque into v_status, v_local from pedidos_venda where id = p_pedido_id;

  if v_status is null then
    raise exception 'Pedido não encontrado';
  end if;

  if v_status = 'confirmado' then
    for item in select produto_id, quantidade from pedido_itens where pedido_id = p_pedido_id and produto_id is not null
    loop
      select id into v_saldo_id from estoque_saldos where produto_id = item.produto_id and local = v_local;

      if v_saldo_id is not null then
        update estoque_saldos set quantidade = quantidade + item.quantidade, updated_at = now() where id = v_saldo_id;
      else
        insert into estoque_saldos (produto_id, local, quantidade) values (item.produto_id, v_local, item.quantidade);
      end if;

      insert into movimentacoes_estoque (produto_id, local, tipo_movimento, quantidade, referencia_tipo, referencia_id)
      values (item.produto_id, v_local, 'cancelamento_venda', item.quantidade, 'pedido_venda_excluido', p_pedido_id);
    end loop;
  end if;

  delete from pedidos_venda where id = p_pedido_id;
end;
$$;

grant execute on function excluir_pedido_venda(uuid) to anon, authenticated;


-- ================================================================
-- ARQUIVO ORIGINAL: 009_transferencia_estoque.sql
-- ================================================================
-- ============================================================
-- ERP E-Factory — TRANSFERÊNCIA DE ESTOQUE ENTRE LOCAIS
-- Cole no SQL Editor.
-- ============================================================

create or replace function transferir_estoque(
  p_produto_id uuid,
  p_origem local_estoque,
  p_destino local_estoque,
  p_quantidade numeric,
  p_observacao text
)
returns void
language plpgsql
security definer
as $$
declare
  v_saldo_origem numeric;
  v_ref_id uuid := gen_random_uuid();
begin
  if p_origem = p_destino then
    raise exception 'O local de origem e destino não podem ser o mesmo.';
  end if;

  if p_quantidade <= 0 then
    raise exception 'A quantidade precisa ser maior que zero.';
  end if;

  select quantidade into v_saldo_origem from estoque_saldos where produto_id = p_produto_id and local = p_origem;

  if v_saldo_origem is null or v_saldo_origem < p_quantidade then
    raise exception 'Estoque insuficiente no local de origem (disponível: %).', coalesce(v_saldo_origem, 0);
  end if;

  -- tira do local de origem
  update estoque_saldos set quantidade = quantidade - p_quantidade, updated_at = now()
    where produto_id = p_produto_id and local = p_origem;

  insert into movimentacoes_estoque (produto_id, local, tipo_movimento, quantidade, referencia_tipo, referencia_id, observacao)
  values (p_produto_id, p_origem, 'transferencia', -p_quantidade, 'transferencia_estoque', v_ref_id, p_observacao);

  -- coloca no local de destino
  insert into estoque_saldos (produto_id, local, quantidade)
  values (p_produto_id, p_destino, p_quantidade)
  on conflict (produto_id, local) do update
    set quantidade = estoque_saldos.quantidade + p_quantidade, updated_at = now();

  insert into movimentacoes_estoque (produto_id, local, tipo_movimento, quantidade, referencia_tipo, referencia_id, observacao)
  values (p_produto_id, p_destino, 'transferencia', p_quantidade, 'transferencia_estoque', v_ref_id, p_observacao);
end;
$$;

grant execute on function transferir_estoque(uuid, local_estoque, local_estoque, numeric, text) to anon, authenticated;


-- ================================================================
-- ARQUIVO ORIGINAL: 010_anuncios_ml.sql
-- ================================================================
-- ============================================================
-- ERP E-Factory — MAPEAMENTO DE ANÚNCIOS ML (por conta)
-- Cole no SQL Editor.
-- ============================================================

create table if not exists produto_anuncios_ml (
  id uuid primary key default gen_random_uuid(),
  produto_id uuid not null references produtos(id) on delete cascade,
  canal canal_venda not null,
  item_id text not null,
  created_at timestamptz not null default now(),
  unique (produto_id, canal)
);

alter table produto_anuncios_ml enable row level security;
create policy "acesso_produto_anuncios_ml" on produto_anuncios_ml for all to authenticated, anon using (true) with check (true);


-- ================================================================
-- NOTA: schema_sku_por_conta.sql foi criado mas REVERTIDO antes de
-- ser aplicado (decidimos manter SKU global, não por conta). Não
-- faz parte do banco atual, mantido só como registro histórico.
-- ================================================================
