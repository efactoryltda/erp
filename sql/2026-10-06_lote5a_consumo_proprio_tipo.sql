-- ============================================================
-- ERP E-Factory — LOTE 5a — CONSUMO PRÓPRIO (parte 1 de 2)
-- Só cria o tipo de movimentação novo "consumo_proprio".
-- (Precisa rodar SOZINHO antes da parte 2: o Postgres só deixa usar
--  um valor novo de tipo depois que ele foi gravado.)
-- Não mexe em dado nenhum.
-- ============================================================
alter type tipo_movimento_estoque add value if not exists 'consumo_proprio';

select 'ok — tipo consumo_proprio criado' as status,
       (select string_agg(e.enumlabel, ', ' order by e.enumsortorder)
          from pg_enum e join pg_type t on t.oid = e.enumtypid
         where t.typname = 'tipo_movimento_estoque') as tipos;
