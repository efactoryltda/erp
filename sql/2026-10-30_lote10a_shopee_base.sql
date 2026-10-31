-- ============================================================
-- ERP E-Factory — LOTE 10a (banco) — base da integração Shopee
-- Decisões (30/10/2026): 1 loja Shopee (canal único 'shopee'); SKUs
-- dos anúncios iguais aos do ML / SKU interno; ERP NÃO envia estoque
-- para a Shopee por enquanto; NF emitida no emissor da Shopee.
--
-- Só ADICIONA. Não altera pedidos, estoque nem lançamentos existentes.
-- Passo 0 (rodar antes, fora de transação — já aplicado):
--   alter type canal_venda add value if not exists 'shopee';
-- ============================================================
begin;

-- Conexão com a loja (tokens nunca vão pra tela: RLS sem política,
-- a tela lê só pelo RPC listar_integracoes_shopee, igual ao ML)
create table if not exists integracoes_shopee (
  id uuid primary key default gen_random_uuid(),
  canal canal_venda not null default 'shopee' unique,
  shop_id bigint unique,
  shop_name text,
  ambiente text not null default 'producao' check (ambiente in ('sandbox', 'producao')),
  access_token text,
  refresh_token text,
  access_expires_at timestamptz,        -- access_token: ~4h
  refresh_expires_at timestamptz,       -- refresh_token: ~30 dias
  autorizacao_expira_em timestamptz,    -- prazo escolhido pela loja (até 365 dias)
  conectado_em timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table integracoes_shopee enable row level security;

create or replace function listar_integracoes_shopee()
returns table (canal text, shop_id bigint, shop_name text, ambiente text,
               conectado_em timestamptz, autorizacao_expira_em timestamptz, refresh_expires_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select canal::text, shop_id, shop_name, ambiente, conectado_em, autorizacao_expira_em, refresh_expires_at
  from integracoes_shopee
$$;
revoke all on function listar_integracoes_shopee() from public, anon;
grant execute on function listar_integracoes_shopee() to authenticated;

-- Pedido e itens da Shopee
alter table pedidos_venda add column if not exists shopee_order_sn text;
alter table pedidos_venda add column if not exists shopee_status text;
create unique index if not exists pedidos_venda_shopee_order_sn_key on pedidos_venda(shopee_order_sn);
comment on column pedidos_venda.shopee_order_sn is 'Nº do pedido na Shopee (order_sn). Preenchido só em pedidos Shopee.';
comment on column pedidos_venda.shopee_status is 'Último order_status lido da Shopee (UNPAID, READY_TO_SHIP, INVOICE_PENDING, SHIPPED, COMPLETED, CANCELLED...).';

alter table pedido_itens add column if not exists shopee_item_id text;
alter table pedido_itens add column if not exists shopee_model_id text;

-- Contas a receber: pedido Shopee NÃO gera o lançamento "à vista recebido"
-- automático (o dinheiro só sai da Shopee depois — será lançado pela
-- integração, como já é feito no ML). Mesmo gatilho, só com WHEN.
drop trigger if exists trg_lancamento_pedido on pedidos_venda;
create trigger trg_lancamento_pedido
  after insert or update of status, valor_total, taxas_canal, data_pedido, canal on pedidos_venda
  for each row when (new.shopee_order_sn is null)
  execute function sync_lancamento_pedido();

-- Lançamentos passam a aceitar o canal e a origem Shopee
alter table lancamentos_financeiros drop constraint lancamentos_financeiros_canal_check;
alter table lancamentos_financeiros add constraint lancamentos_financeiros_canal_check
  check (canal = any (array['ml_conta1','ml_conta2','ml_conta3','shopee','loja_fisica','loja_online','outros']));
alter table lancamentos_financeiros drop constraint lancamentos_financeiros_origem_check;
alter table lancamentos_financeiros add constraint lancamentos_financeiros_origem_check
  check (origem = any (array['ml','shopee','pedido','manual']));

commit;
