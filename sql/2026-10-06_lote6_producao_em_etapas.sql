-- ============================================================
-- ERP E-Factory — LOTE 6 — PRODUÇÃO EM ETAPAS
-- (ex: Chapa → Chapa Cortada → Caixa)
--   1. Ficha técnica: trava contra CICLO (A usa B que usa A).
--   2. concluir_ordem_producao (alteração cirúrgica, o resto igual):
--      • produto que é MATÉRIA-PRIMA (ex: chapa cortada) pode ser produzido
--        e vai pro estoque "materia_prima"; produto acabado continua indo
--        pro Físico ou Full (como antes).
--      • se algum componente consumido estiver SEM CUSTO (custo 0), a
--        produção acontece normal, mas o custo médio do produto feito
--        NÃO é alterado (custo zero não contamina o custo de verdade).
--   NÃO cadastra produto nem ficha (isso fica com a equipe).
--   Confere sozinho: muda só esses trechos, testa tudo (com produtos de
--   teste que são apagados no fim) e confirma que faturamento, estoque,
--   produtos e fichas ficaram iguais.
-- Cole TUDO no Supabase → SQL Editor → RUN ("Run without RLS" se avisar).
-- ============================================================
begin;

create temp table _antes on commit drop as
  select (select coalesce(sum(valor_total) filter (where status = 'confirmado'), 0) from pedidos_venda) as fat,
         (select coalesce(sum(quantidade), 0) from estoque_saldos) as estoque,
         (select count(*) from estoque_saldos) as n_saldos,
         (select count(*) from movimentacoes_estoque) as n_mov,
         (select count(*) from produtos) as n_prod,
         (select coalesce(sum(custo_atual), 0) from produtos) as soma_custos,
         (select count(*) from ficha_tecnica_itens) as n_ficha,
         (select count(*) from ordens_producao) as n_ordens;

-- ---------- 1. trava contra ciclo na ficha técnica ----------
-- confere que não existe ciclo HOJE (senão a trava nem faria sentido)
do $$
begin
  if exists (
    with recursive abaixo as (
      select f.produto_acabado_id as raiz, f.produto_materia_prima_id as comp, 1 as n from ficha_tecnica_itens f
      union all
      select a.raiz, f.produto_materia_prima_id, a.n + 1
      from abaixo a join ficha_tecnica_itens f on f.produto_acabado_id = a.comp
      where a.n < 20)
    select 1 from abaixo where comp = raiz) then
    raise exception 'PARADO: já existe uma ficha em ciclo no banco. Nada foi aplicado.';
  end if;
end $$;

create or replace function ficha_bloquear_ciclo()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (
    with recursive abaixo as (
      select new.produto_materia_prima_id as comp, 1 as n
      union all
      select f.produto_materia_prima_id, a.n + 1
      from abaixo a join ficha_tecnica_itens f on f.produto_acabado_id = a.comp
      where a.n < 20)
    select 1 from abaixo where comp = new.produto_acabado_id) then
    raise exception 'Não dá: esse componente já usa (direta ou indiretamente) o produto que está sendo feito — a ficha ficaria em ciclo.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ficha_bloquear_ciclo on ficha_tecnica_itens;
create trigger trg_ficha_bloquear_ciclo
  before insert or update of produto_acabado_id, produto_materia_prima_id on ficha_tecnica_itens
  for each row execute function ficha_bloquear_ciclo();

-- ---------- 2. concluir_ordem_producao: troca SÓ 5 trechos ----------
do $$
declare
  v_def text;
  v_novo text;
  trechos text[][] := array[
    -- (a função foi gravada com quebra de linha do Windows: \r\n)
    [E'  v_obs text;\r\n  item record;\r\nbegin',
     E'  v_obs text;\r\n  item record;\r\n  v_sem_custo integer := 0;   -- componentes consumidos sem custo (Lote 6)\r\nbegin'],
    [$t$p_local_destino not in ('fisico', 'full_conta1', 'full_conta2', 'full_conta3')$t$,
     $t$((select tipo from produtos where id = v_produto_acabado_id) = 'materia_prima' and p_local_destino <> 'materia_prima')
     or ((select tipo from produtos where id = v_produto_acabado_id) <> 'materia_prima'
         and p_local_destino not in ('fisico', 'full_conta1', 'full_conta2', 'full_conta3'))$t$],
    [$t$v_custo_total := v_custo_total + v_qtd_consumo * coalesce(item.custo_atual, 0);$t$,
     $t$v_custo_total := v_custo_total + v_qtd_consumo * coalesce(item.custo_atual, 0);
    if coalesce(item.custo_atual, 0) <= 0 then v_sem_custo := v_sem_custo + 1; end if;$t$],
    [$t$set custo_atual = calc_custo_medio($t$,
     $t$set custo_atual = case when v_sem_custo > 0 then custo_atual else calc_custo_medio($t$],
    [$t$v_custo_total / p_quantidade_produzida),$t$,
     $t$v_custo_total / p_quantidade_produzida) end,$t$]
  ];
  i int;
  n int;
begin
  v_def := pg_get_functiondef('public.concluir_ordem_producao(uuid, numeric, local_estoque, boolean)'::regprocedure);
  v_novo := v_def;
  for i in 1 .. array_length(trechos, 1) loop
    n := (length(v_novo) - length(replace(v_novo, trechos[i][1], ''))) / length(trechos[i][1]);
    if n <> 1 then
      raise exception 'PARADO: trecho % da função de produção apareceu % vez(es) (esperado 1) — a função no banco mudou. Nada foi aplicado.', i, n;
    end if;
    v_novo := replace(v_novo, trechos[i][1], trechos[i][2]);
  end loop;
  execute v_novo;
end $$;

-- ---------- teste completo (tudo desfeito no fim) ----------
do $$
declare
  ch uuid; cc uuid; cx uuid; ch0 uuid; cx0 uuid; o1 uuid; o2 uuid; o3 uuid;
  v numeric; c numeric; ok_ciclo boolean := false; ok_destino boolean := false;
begin
  begin
    insert into produtos (sku_interno, nome, tipo, unidade_medida, custo_atual)
      values ('ZZTESTE-CHAPA', 'teste chapa', 'materia_prima', 'UN', 2) returning id into ch;
    insert into produtos (sku_interno, nome, tipo, unidade_medida, custo_atual)
      values ('ZZTESTE-CORTADA', 'teste cortada', 'materia_prima', 'UN', 0) returning id into cc;
    insert into produtos (sku_interno, nome, tipo, unidade_medida, custo_atual)
      values ('ZZTESTE-CAIXA', 'teste caixa', 'produto_acabado', 'UN', 0) returning id into cx;
    insert into ficha_tecnica_itens (produto_acabado_id, produto_materia_prima_id, quantidade_necessaria) values (cc, ch, 1);
    insert into ficha_tecnica_itens (produto_acabado_id, produto_materia_prima_id, quantidade_necessaria) values (cx, cc, 1);

    -- trava de ciclo: chapa usando caixa tem que falhar
    begin
      insert into ficha_tecnica_itens (produto_acabado_id, produto_materia_prima_id, quantidade_necessaria) values (ch, cx, 1);
    exception when raise_exception then ok_ciclo := true;
    end;
    if not ok_ciclo then raise exception 'PARADO: a trava de ciclo não funcionou.'; end if;

    -- etapa 1: cortar 5 (matéria-prima → matéria-prima)
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (cc, 5, 'em_producao') returning id into o1;
    begin
      perform concluir_ordem_producao(o1, 5, 'fisico', false);       -- destino errado tem que falhar
    exception when raise_exception then ok_destino := true;
    end;
    if not ok_destino then raise exception 'PARADO: aceitou matéria-prima indo pro Físico.'; end if;
    perform concluir_ordem_producao(o1, 5, 'materia_prima', false);
    select quantidade into v from estoque_saldos where produto_id = ch and local = 'materia_prima';
    if v <> -5 then raise exception 'PARADO: chapa não baixou 5 (%).', v; end if;
    select quantidade into v from estoque_saldos where produto_id = cc and local = 'materia_prima';
    if v <> 5 then raise exception 'PARADO: chapa cortada não entrou 5 (%).', v; end if;
    select custo_atual into c from produtos where id = cc;
    if c <> 2 then raise exception 'PARADO: custo da cortada deveria ser 2 (%).', c; end if;

    -- etapa 2: colar 5 (cortada → caixa no Físico)
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (cx, 5, 'em_producao') returning id into o2;
    perform concluir_ordem_producao(o2, 5, 'fisico', false);
    select quantidade into v from estoque_saldos where produto_id = cc and local = 'materia_prima';
    if v <> 0 then raise exception 'PARADO: cortada não baixou (%).', v; end if;
    select quantidade into v from estoque_saldos where produto_id = cx and local = 'fisico';
    if v <> 5 then raise exception 'PARADO: caixa não entrou no Físico (%).', v; end if;
    select custo_atual into c from produtos where id = cx;
    if c <> 2 then raise exception 'PARADO: custo da caixa deveria ser 2 (%).', c; end if;

    -- proteção: componente sem custo não mexe no custo médio
    insert into produtos (sku_interno, nome, tipo, unidade_medida, custo_atual)
      values ('ZZTESTE-CHAPA0', 'teste chapa sem custo', 'materia_prima', 'UN', 0) returning id into ch0;
    insert into produtos (sku_interno, nome, tipo, unidade_medida, custo_atual)
      values ('ZZTESTE-CAIXA0', 'teste caixa com custo', 'produto_acabado', 'UN', 1.5) returning id into cx0;
    insert into ficha_tecnica_itens (produto_acabado_id, produto_materia_prima_id, quantidade_necessaria) values (cx0, ch0, 1);
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (cx0, 3, 'em_producao') returning id into o3;
    perform concluir_ordem_producao(o3, 3, 'fisico', false);
    select custo_atual into c from produtos where id = cx0;
    if c <> 1.5 then raise exception 'PARADO: custo zero contaminou o custo (1,5 → %).', c; end if;

    raise exception 'TESTE_OK';     -- desfaz tudo que o teste gravou
  exception when raise_exception then
    if sqlerrm <> 'TESTE_OK' then raise; end if;
  end;
end $$;

-- ---------- conferência final ----------
do $$
declare a record; d record;
begin
  select * into a from _antes;
  select (select coalesce(sum(valor_total) filter (where status = 'confirmado'), 0) from pedidos_venda) as fat,
         (select coalesce(sum(quantidade), 0) from estoque_saldos) as estoque,
         (select count(*) from estoque_saldos) as n_saldos,
         (select count(*) from movimentacoes_estoque) as n_mov,
         (select count(*) from produtos) as n_prod,
         (select coalesce(sum(custo_atual), 0) from produtos) as soma_custos,
         (select count(*) from ficha_tecnica_itens) as n_ficha,
         (select count(*) from ordens_producao) as n_ordens
    into d;
  if row(a.fat, a.estoque, a.n_saldos, a.n_mov, a.n_prod, a.soma_custos, a.n_ficha, a.n_ordens)
     is distinct from row(d.fat, d.estoque, d.n_saldos, d.n_mov, d.n_prod, d.soma_custos, d.n_ficha, d.n_ordens) then
    raise exception 'PARADO: algo mudou além das funções. Nada foi aplicado.';
  end if;
end $$;

commit;

select 'ok — produção em etapas pronta; teste passou; nada de dado mudou' as status,
       (select count(*) from ficha_tecnica_itens) as fichas,
       (select count(*) from produtos) as produtos;
