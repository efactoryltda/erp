-- ============================================================
-- ERP E-Factory — LOTE 8a — ESTORNO DE ORDEM DE PRODUÇÃO (tipos)
--   Só adiciona 2 valores novos de lista (enum). Não mexe em dado.
--   • status de OP:         'estornada'
--   • tipo de movimentação: 'estorno_op'
-- Precisa rodar ANTES (e separado) do Lote 8b: o Postgres não deixa
-- usar um valor de enum novo na mesma transação em que ele foi criado.
-- ============================================================
alter type status_ordem_producao  add value if not exists 'estornada';
alter type tipo_movimento_estoque add value if not exists 'estorno_op';
