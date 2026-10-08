-- ============================================================
-- ERP E-Factory — LOTE 8b — ESTORNO DE ORDEM DE PRODUÇÃO
-- Rodar DEPOIS do Lote 8a (tipos 'estornada' e 'estorno_op').
--
--   1. ordens_producao ganha colunas:
--        • do estorno: estornada_em, estornada_por, estornada_por_email,
--          observacao_estorno
--        • do custo (gravadas na CONCLUSÃO, pra o estorno ser exato):
--          custo_produto_antes, custo_produto_depois, saldo_produto_antes,
--          custo_alterado_pela_op
--   2. concluir_ordem_producao: alteração cirúrgica — troca SÓ 1 trecho,
--      pra passar a gravar essas 4 colunas de custo. O resto fica igual.
--   3. previa_estorno_ordem_producao(op): mostra o que volta, o que sai,
--      o que bloqueia e o que acontece com o custo. Não grava nada.
--   4. estornar_ordem_producao(op, observacao): inverte EXATAMENTE as
--      movimentações daquela OP (mesmo produto, mesmo local), grava cada
--      uma como 'estorno_op' ligada à OP, ajusta o custo e marca a OP
--      como 'estornada'. Bloqueia se faltar saldo de algo que precisa sair.
--   5. Trava (trigger): OP concluída/estornada não pode ser excluída, e o
--      status dela não muda "na mão" (só pelos botões).
--
-- Regras de custo do estorno (só do produto feito; componentes não mudam):
--   • OP antiga (antes deste lote, sem registro): custo mantido + aviso.
--   • A conclusão não mexeu no custo (componente sem custo): mantido.
--   • Nada mexeu no custo depois da OP: volta EXATAMENTE ao de antes.
--   • Outra entrada mexeu no custo depois: tira a parte desta OP pela
--     conta inversa da média ponderada (aproximado). Se não der pra fazer
--     com segurança (estoque restante <= 0, resultado <= 0, ou a OP tinha
--     substituído o custo em vez de ponderar), mantém + aviso.
--
-- Confere sozinho: testa tudo com produtos de teste (desfeitos no fim) e
-- confirma que estoque, movimentações, produtos, custos, fichas e ordens
-- ficaram iguais. Se algo não bater, PARA e nada é aplicado.
-- Cole TUDO no Supabase → SQL Editor → RUN.
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
         (select count(*) from ordens_producao) as n_ordens,
         (select count(*) from ordens_producao where status = 'concluida') as n_concluidas;

-- ---------- 1. colunas novas ----------
alter table ordens_producao
  add column if not exists estornada_em           timestamptz,
  add column if not exists estornada_por          uuid,
  add column if not exists estornada_por_email    text,
  add column if not exists observacao_estorno     text,
  add column if not exists custo_produto_antes    numeric(14,6),
  add column if not exists custo_produto_depois   numeric(14,6),
  add column if not exists saldo_produto_antes    numeric(14,3),
  add column if not exists custo_alterado_pela_op boolean;

comment on column ordens_producao.custo_produto_antes    is 'Custo do produto feito ANTES desta OP (gravado na conclusão; usado pelo estorno).';
comment on column ordens_producao.custo_produto_depois   is 'Custo do produto feito logo DEPOIS desta OP (gravado na conclusão).';
comment on column ordens_producao.saldo_produto_antes    is 'Saldo total (todos os locais) do produto feito antes da entrada desta OP.';
comment on column ordens_producao.custo_alterado_pela_op is 'false = a conclusão não mexeu no custo (havia componente sem custo).';

-- ---------- 2. concluir_ordem_producao: troca SÓ 1 trecho ----------
do $$
declare
  v_def text;
  v_de  text := $t$set status = 'concluida',$t$;
  v_para text := $t$set status = 'concluida',
        custo_produto_antes    = v_custo_ant,   -- Lote 8 (estorno)
        saldo_produto_antes    = v_saldo,
        custo_produto_depois   = (select custo_atual from produtos where id = v_produto_acabado_id),
        custo_alterado_pela_op = (v_sem_custo = 0),$t$;
  n int;
begin
  v_def := pg_get_functiondef('public.concluir_ordem_producao(uuid, numeric, local_estoque, boolean)'::regprocedure);
  if position('custo_produto_antes' in v_def) > 0 then
    raise exception 'PARADO: a função de produção já grava o custo (lote aplicado antes?). Nada foi aplicado.';
  end if;
  n := (length(v_def) - length(replace(v_def, v_de, ''))) / length(v_de);
  if n <> 1 then
    raise exception 'PARADO: trecho da função de produção apareceu % vez(es) (esperado 1) — a função no banco mudou. Nada foi aplicado.', n;
  end if;
  execute replace(v_def, v_de, v_para);
end $$;

-- ---------- 3. nome amigável do local ----------
create or replace function rotulo_local_estoque(p_local local_estoque)
returns text
language sql
immutable
set search_path = public
as $$
  select case p_local::text
    when 'fisico'        then 'Físico'
    when 'materia_prima' then 'Matéria-prima'
    when 'full_conta1'   then 'ML Full - E-Factory'
    when 'full_conta2'   then 'ML Full - JG'
    when 'full_conta3'   then 'ML Full - Gustavo Baruffi'
    when 'full'          then 'Full (genérico)'
    else p_local::text end;
$$;

-- ---------- 4. prévia do estorno (não grava nada) ----------
create or replace function previa_estorno_ordem_producao(p_ordem_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_op ordens_producao%rowtype;
  v_itens jsonb;
  v_bloqueios jsonb;
  v_prod record;
  v_q numeric;
  v_e numeric;
  v_s_now numeric;
  v_c_new numeric;
  v_ultimo_mov timestamptz;
  v_acao text;
  v_motivo text;
begin
  select * into v_op from ordens_producao where id = p_ordem_id;
  if not found then
    raise exception 'Ordem de produção não encontrada (OP excluída não tem estorno).';
  end if;
  if v_op.status = 'estornada' then
    raise exception 'Esta OP já foi estornada em % por %. Não dá pra estornar de novo.',
      to_char(v_op.estornada_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
      coalesce(v_op.estornada_por_email, '—');
  end if;
  if v_op.status <> 'concluida' then
    raise exception 'Só dá pra estornar OP concluída (esta está "%").', v_op.status;
  end if;

  -- o que a OP fez, por produto e local → o estorno é o contrário
  with mov as (
    select m.produto_id, m.local, sum(m.quantidade) as qtd_op
    from movimentacoes_estoque m
    where m.referencia_tipo = 'ordem_producao'
      and m.referencia_id = p_ordem_id
      and m.tipo_movimento in ('producao_consumo', 'producao_entrada')
    group by m.produto_id, m.local
    having sum(m.quantidade) <> 0
  ), x as (
    select mov.produto_id, mov.local, -mov.qtd_op as qtd, p.nome, p.sku_interno,
           coalesce(s.quantidade, 0) as saldo,
           (select string_agg(rotulo_local_estoque(s2.local) || ': '
                              || replace(trim_scale(s2.quantidade)::text, '.', ','), '; ' order by s2.local)
              from estoque_saldos s2
             where s2.produto_id = mov.produto_id and s2.local <> mov.local and s2.quantidade > 0) as outros
    from mov
    join produtos p on p.id = mov.produto_id
    left join estoque_saldos s on s.produto_id = mov.produto_id and s.local = mov.local
  )
  select
    jsonb_agg(jsonb_build_object(
        'produto_id', produto_id, 'produto', nome, 'sku', sku_interno,
        'local', local, 'local_nome', rotulo_local_estoque(local),
        'quantidade', qtd, 'saldo_atual', saldo, 'saldo_depois', saldo + qtd,
        'falta', case when qtd < 0 and saldo + qtd < 0 then -(saldo + qtd) else 0 end,
        'outros_locais', outros)
      order by qtd desc, nome),
    coalesce(jsonb_agg(
        format('%s (%s): o estorno precisa tirar %s do estoque "%s", que tem só %s — faltam %s.%s',
               nome, sku_interno,
               replace(trim_scale(-qtd)::text, '.', ','), rotulo_local_estoque(local),
               replace(trim_scale(saldo)::text, '.', ','),
               replace(trim_scale(-(saldo + qtd))::text, '.', ','),
               case when outros is not null
                    then ' Em outros locais: ' || outros || '. Se foi transferido, transfira de volta antes de estornar.'
                    else ' Provavelmente já foi vendido ou usado.' end)
        order by nome) filter (where qtd < 0 and saldo + qtd < 0), '[]'::jsonb)
  into v_itens, v_bloqueios
  from x;

  if v_itens is null then
    raise exception 'Esta OP não tem movimentações de estoque registradas — não há o que estornar.';
  end if;

  -- custo do produto feito
  select id, nome, custo_atual into v_prod from produtos where id = v_op.produto_acabado_id;
  v_q := v_op.quantidade_produzida;
  v_e := v_op.custo_producao_total / nullif(v_q, 0);
  select max(created_at) into v_ultimo_mov
    from movimentacoes_estoque
   where referencia_tipo = 'ordem_producao' and referencia_id = p_ordem_id;

  if v_op.custo_produto_depois is null then
    v_acao := 'mantido';
    v_motivo := 'OP concluída antes do registro de custo (Lote 8): o estorno não mexe no custo. Confira o custo de "' || v_prod.nome || '".';
  elsif not coalesce(v_op.custo_alterado_pela_op, false) then
    v_acao := 'mantido';
    v_motivo := 'A conclusão desta OP não mexeu no custo (tinha componente sem custo), então o estorno também não mexe.';
  elsif v_prod.custo_atual = v_op.custo_produto_depois
        and not exists (
          select 1 from movimentacoes_estoque m
           where m.produto_id = v_op.produto_acabado_id
             and m.tipo_movimento in ('compra', 'estorno_compra', 'producao_entrada', 'estorno_op')
             and m.created_at > v_ultimo_mov
             and not (m.referencia_tipo = 'ordem_producao' and m.referencia_id = p_ordem_id)
             -- entradas que já foram desfeitas (OP estornada / OC estornada) não contam
             and not (m.referencia_tipo = 'ordem_producao'
                      and exists (select 1 from ordens_producao o2 where o2.id = m.referencia_id and o2.status = 'estornada'))
             and not (m.referencia_tipo = 'ordem_compra'
                      and exists (select 1 from ordens_compra oc where oc.id = m.referencia_id and oc.status <> 'recebida'))) then
    v_acao := 'restaurado';
    v_c_new := v_op.custo_produto_antes;
    v_motivo := 'Nada mexeu no custo depois desta OP: volta exatamente ao custo de antes.';
  elsif coalesce(v_op.saldo_produto_antes, 0) > 0 and coalesce(v_op.custo_produto_antes, 0) > 0 and v_e is not null then
    select coalesce(sum(quantidade), 0) into v_s_now from estoque_saldos where produto_id = v_op.produto_acabado_id;
    if v_s_now - v_q > 0 then
      v_c_new := round((v_prod.custo_atual * v_s_now - v_q * v_e) / (v_s_now - v_q), 6);
    end if;
    if v_c_new is not null and v_c_new > 0 then
      v_acao := 'recalculado';
      v_motivo := 'O custo mudou depois desta OP (outra entrada): recalculado tirando a parte desta OP (valor aproximado).';
    else
      v_acao := 'mantido';
      v_c_new := null;
      v_motivo := 'O custo mudou depois desta OP e não dá pra recalcular com segurança (estoque restante ficaria zerado/negativo). Confira o custo de "' || v_prod.nome || '".';
    end if;
  else
    v_acao := 'mantido';
    v_motivo := 'O custo mudou depois desta OP e o custo de antes dela não pode ser reconstruído. Confira o custo de "' || v_prod.nome || '".';
  end if;

  return jsonb_build_object(
    'ordem_id', v_op.id,
    'produto', v_prod.nome,
    'quantidade_produzida', v_q,
    'pode_estornar', jsonb_array_length(v_bloqueios) = 0,
    'bloqueios', v_bloqueios,
    'itens', v_itens,
    'custo', jsonb_build_object('acao', v_acao, 'custo_atual', v_prod.custo_atual,
                                'custo_novo', v_c_new, 'motivo', v_motivo));
end;
$$;

-- ---------- 5. estorno ----------
create or replace function estornar_ordem_producao(p_ordem_id uuid, p_observacao text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_produto uuid;
  v_prev jsonb;
  v_obs text := nullif(btrim(p_observacao), '');
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  item record;
begin
  -- trava a OP (dois cliques ao mesmo tempo: o segundo espera e depois falha)
  select produto_acabado_id into v_produto from ordens_producao where id = p_ordem_id for update;
  if not found then
    raise exception 'Ordem de produção não encontrada (OP excluída não tem estorno).';
  end if;

  -- trava os saldos envolvidos e o custo do produto enquanto confere
  perform 1 from estoque_saldos s
   where (s.produto_id, s.local) in (
     select m.produto_id, m.local from movimentacoes_estoque m
      where m.referencia_tipo = 'ordem_producao' and m.referencia_id = p_ordem_id)
   for update;
  perform 1 from produtos where id = v_produto for update;

  v_prev := previa_estorno_ordem_producao(p_ordem_id);

  if not (v_prev ->> 'pode_estornar')::boolean then
    raise exception 'Estorno bloqueado — saldo insuficiente. %',
      (select string_agg(b, ' | ') from jsonb_array_elements_text(v_prev -> 'bloqueios') b);
  end if;

  for item in
    select * from jsonb_to_recordset(v_prev -> 'itens') as t(produto_id uuid, local local_estoque, quantidade numeric)
  loop
    insert into estoque_saldos (produto_id, local, quantidade)
    values (item.produto_id, item.local, item.quantidade)
    on conflict (produto_id, local) do update
      set quantidade = estoque_saldos.quantidade + item.quantidade, updated_at = now();

    insert into movimentacoes_estoque
      (produto_id, local, tipo_movimento, quantidade, referencia_tipo, referencia_id,
       observacao, usuario_email, data_referencia)
    values
      (item.produto_id, item.local, 'estorno_op', item.quantidade, 'ordem_producao', p_ordem_id,
       'Estorno de OP' || coalesce(': ' || v_obs, ''), auth.jwt() ->> 'email', v_hoje);
  end loop;

  if v_prev -> 'custo' ->> 'acao' in ('restaurado', 'recalculado') then
    update produtos
       set custo_atual = (v_prev -> 'custo' ->> 'custo_novo')::numeric, updated_at = now()
     where id = v_produto;
  end if;

  perform set_config('erp.op_estorno', '1', true);
  update ordens_producao
     set status = 'estornada',
         estornada_em = now(),
         estornada_por = auth.uid(),
         estornada_por_email = auth.jwt() ->> 'email',
         observacao_estorno = v_obs,
         updated_at = now()
   where id = p_ordem_id;
  perform set_config('erp.op_estorno', '', true);

  return v_prev || jsonb_build_object('estornada', true);
end;
$$;

revoke all on function previa_estorno_ordem_producao(uuid) from public, anon;
revoke all on function estornar_ordem_producao(uuid, text) from public, anon;
grant execute on function previa_estorno_ordem_producao(uuid) to authenticated;
grant execute on function estornar_ordem_producao(uuid, text) to authenticated;

-- ---------- 6. trava: não excluir / não mudar status "na mão" ----------
create or replace function ordens_producao_proteger()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    if old.status in ('concluida', 'estornada') then
      raise exception 'Esta OP está "%" e não pode ser excluída: ela já mexeu no estoque. Use "Estornar" — o histórico fica guardado.', old.status;
    end if;
    return old;
  end if;

  if new.status is distinct from old.status then
    if new.status = 'estornada' and coalesce(current_setting('erp.op_estorno', true), '') <> '1' then
      raise exception 'Para estornar uma OP use o botão "Estornar" (ele devolve o estoque).';
    end if;
    if old.status in ('concluida', 'estornada')
       and not (old.status = 'concluida' and new.status = 'estornada') then
      raise exception 'O status de uma OP "%" não pode ser alterado manualmente.', old.status;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ordens_producao_proteger on ordens_producao;
create trigger trg_ordens_producao_proteger
  before update or delete on ordens_producao
  for each row execute function ordens_producao_proteger();

-- ---------- teste completo (tudo desfeito no fim) ----------
-- Num único RUN o relógio do banco não anda (now() é o mesmo pra tudo), então o
-- teste empurra o horário de cada OP concluída alguns segundos pra frente,
-- simulando OPs feitas uma depois da outra, como no uso real.
do $$
declare
  ch uuid; cx uuid; kit uuid; ch0 uuid; cx0 uuid;
  o1 uuid; o2 uuid; o3 uuid; o4 uuid; o5 uuid; o6 uuid; o7 uuid; o8 uuid; o9 uuid;
  v numeric; c numeric; n int; e text; j jsonb; st status_ordem_producao;
  antes jsonb; depois jsonb;
  k int := 0;   -- relógio simulado: cada OP concluída fica k segundos "mais tarde"
begin
  begin
    insert into produtos (sku_interno, nome, tipo, unidade_medida, custo_atual)
      values ('ZZTESTE8-CHAPA', 'teste8 chapa', 'materia_prima', 'UN', 2) returning id into ch;
    insert into produtos (sku_interno, nome, tipo, unidade_medida, custo_atual)
      values ('ZZTESTE8-CAIXA', 'teste8 caixa', 'produto_acabado', 'UN', 1) returning id into cx;
    insert into produtos (sku_interno, nome, tipo, unidade_medida, custo_atual)
      values ('ZZTESTE8-KIT', 'teste8 kit 2 caixas', 'produto_acabado', 'UN', 0) returning id into kit;
    insert into ficha_tecnica_itens (produto_acabado_id, produto_materia_prima_id, quantidade_necessaria) values (cx, ch, 1);
    insert into ficha_tecnica_itens (produto_acabado_id, produto_materia_prima_id, quantidade_necessaria) values (kit, cx, 2);
    insert into estoque_saldos (produto_id, local, quantidade) values (ch, 'materia_prima', 1000), (cx, 'fisico', 100);

    select jsonb_object_agg(produto_id || '|' || local, quantidade) into antes
      from estoque_saldos where produto_id in (ch, cx, kit);

    -- T1: concluir 100 caixas e estornar → saldos e custo exatamente como antes
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (cx, 100, 'em_producao') returning id into o1;
    perform concluir_ordem_producao(o1, 100, 'fisico', false);
    k := k + 1; update movimentacoes_estoque set created_at = created_at + make_interval(secs => k) where referencia_tipo = 'ordem_producao' and referencia_id = o1;
    select custo_atual into c from produtos where id = cx;
    if c <> 1.5 then raise exception 'PARADO T1: custo após conclusão deveria ser 1,5 (%).', c; end if;
    if (select row(custo_produto_antes, custo_produto_depois, saldo_produto_antes, custo_alterado_pela_op)::text from ordens_producao where id = o1)
       <> row(1::numeric(14,6), 1.5::numeric(14,6), 100::numeric(14,3), true)::text then
      raise exception 'PARADO T1: a conclusão não gravou o custo antes/depois certo.';
    end if;
    j := previa_estorno_ordem_producao(o1);
    if not (j ->> 'pode_estornar')::boolean or j -> 'custo' ->> 'acao' <> 'restaurado' or jsonb_array_length(j -> 'itens') <> 2 then
      raise exception 'PARADO T1: prévia inesperada: %', j;
    end if;
    -- a prévia não pode gravar nada
    if (select count(*) from movimentacoes_estoque where referencia_id = o1 and tipo_movimento = 'estorno_op') <> 0 then
      raise exception 'PARADO T1: a prévia gravou movimentação.';
    end if;
    perform estornar_ordem_producao(o1, '  teste de estorno  ');
    select jsonb_object_agg(produto_id || '|' || local, quantidade) into depois
      from estoque_saldos where produto_id in (ch, cx, kit);
    if antes is distinct from depois then raise exception 'PARADO T1: saldos não voltaram: antes % depois %', antes, depois; end if;
    select custo_atual into c from produtos where id = cx;
    if c <> 1 then raise exception 'PARADO T1: custo não voltou a 1 (%).', c; end if;
    select status into st from ordens_producao where id = o1;
    if st <> 'estornada' then raise exception 'PARADO T1: OP não ficou estornada (%).', st; end if;
    if (select observacao_estorno from ordens_producao where id = o1) <> 'teste de estorno'
       or (select estornada_em from ordens_producao where id = o1) is null then
      raise exception 'PARADO T1: não gravou observação/data do estorno.';
    end if;
    select count(*), sum(quantidade) into n, v from movimentacoes_estoque
     where referencia_tipo = 'ordem_producao' and referencia_id = o1 and tipo_movimento = 'estorno_op';
    if n <> 2 or v <> 0 then raise exception 'PARADO T1: movimentos estorno_op errados (n=%, soma=%).', n, v; end if;
    if (select sum(quantidade) from movimentacoes_estoque where referencia_id = o1) <> 0 then
      raise exception 'PARADO T1: produção + estorno não somam zero.';
    end if;

    -- T1b: novo estorno da mesma OP tem que falhar
    e := null;
    begin perform estornar_ordem_producao(o1); exception when raise_exception then e := sqlerrm; end;
    if e is null or e not like '%já foi estornada%' then raise exception 'PARADO T1b: aceitou estornar 2x (%).', e; end if;

    -- T1c: OP estornada / concluída não pode ser excluída nem ter status mudado na mão
    e := null;
    begin delete from ordens_producao where id = o1; exception when raise_exception then e := sqlerrm; end;
    if e is null then raise exception 'PARADO T1c: deixou excluir OP estornada.'; end if;
    e := null;
    begin update ordens_producao set status = 'concluida' where id = o1; exception when raise_exception then e := sqlerrm; end;
    if e is null then raise exception 'PARADO T1c: deixou "desestornar" na mão.'; end if;

    -- T2: saldo insuficiente bloqueia e não muda nada; depois de devolver, estorna
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (cx, 50, 'em_producao') returning id into o2;
    perform concluir_ordem_producao(o2, 50, 'fisico', false);          -- caixa físico 150
    k := k + 1; update movimentacoes_estoque set created_at = created_at + make_interval(secs => k) where referencia_tipo = 'ordem_producao' and referencia_id = o2;
    e := null;
    begin delete from ordens_producao where id = o2; exception when raise_exception then e := sqlerrm; end;
    if e is null then raise exception 'PARADO T2: deixou excluir OP concluída.'; end if;
    e := null;
    begin update ordens_producao set status = 'estornada' where id = o2; exception when raise_exception then e := sqlerrm; end;
    if e is null then raise exception 'PARADO T2: deixou marcar estornada sem devolver estoque.'; end if;
    e := null;
    begin update ordens_producao set status = 'cancelada' where id = o2; exception when raise_exception then e := sqlerrm; end;
    if e is null then raise exception 'PARADO T2: deixou mudar status de OP concluída na mão.'; end if;

    update estoque_saldos set quantidade = quantidade - 120 where produto_id = cx and local = 'fisico';   -- simula transferência
    insert into estoque_saldos (produto_id, local, quantidade) values (cx, 'full_conta1', 120);
    select jsonb_object_agg(produto_id || '|' || local, quantidade) into antes from estoque_saldos where produto_id in (ch, cx, kit);
    e := null;
    begin perform estornar_ordem_producao(o2); exception when raise_exception then e := sqlerrm; end;
    if e is null or e not like '%faltam 20%' or e not like '%ML Full - E-Factory: 120%' then
      raise exception 'PARADO T2: bloqueio não veio como esperado (%).', e;
    end if;
    select jsonb_object_agg(produto_id || '|' || local, quantidade) into depois from estoque_saldos where produto_id in (ch, cx, kit);
    if antes is distinct from depois then raise exception 'PARADO T2: bloqueio mexeu no estoque.'; end if;
    if (select status from ordens_producao where id = o2) <> 'concluida' then raise exception 'PARADO T2: bloqueio mudou status.'; end if;
    update estoque_saldos set quantidade = quantidade + 120 where produto_id = cx and local = 'fisico';
    update estoque_saldos set quantidade = quantidade - 120 where produto_id = cx and local = 'full_conta1';
    perform estornar_ordem_producao(o2);
    select quantidade into v from estoque_saldos where produto_id = cx and local = 'fisico';
    if v <> 100 then raise exception 'PARADO T2: caixa físico deveria voltar a 100 (%).', v; end if;
    select quantidade into v from estoque_saldos where produto_id = ch and local = 'materia_prima';
    if v <> 1000 then raise exception 'PARADO T2: chapa deveria voltar a 1000 (%).', v; end if;
    select custo_atual into c from produtos where id = cx;
    if c <> 1 then raise exception 'PARADO T2: custo deveria voltar a 1 (%).', c; end if;

    -- T3: outra OP mexeu no custo depois → conta inversa
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (cx, 100, 'em_producao') returning id into o3;
    perform concluir_ordem_producao(o3, 100, 'fisico', false);          -- custo 1,5
    k := k + 1; update movimentacoes_estoque set created_at = created_at + make_interval(secs => k) where referencia_tipo = 'ordem_producao' and referencia_id = o3;
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (cx, 100, 'em_producao') returning id into o4;
    perform concluir_ordem_producao(o4, 100, 'fisico', false);          -- custo 1,666667
    k := k + 1; update movimentacoes_estoque set created_at = created_at + make_interval(secs => k) where referencia_tipo = 'ordem_producao' and referencia_id = o4;
    j := estornar_ordem_producao(o3);
    if j -> 'custo' ->> 'acao' <> 'recalculado' then raise exception 'PARADO T3: esperado recalculado (%).', j -> 'custo'; end if;
    select custo_atual into c from produtos where id = cx;
    if abs(c - 1.5) > 0.00001 then raise exception 'PARADO T3: custo deveria ser ~1,5 (%).', c; end if;
    perform estornar_ordem_producao(o4);
    select custo_atual into c from produtos where id = cx;
    if abs(c - 1) > 0.0001 then raise exception 'PARADO T3: custo deveria voltar a ~1 (%).', c; end if;
    select quantidade into v from estoque_saldos where produto_id = cx and local = 'fisico';
    if v <> 100 then raise exception 'PARADO T3: caixa físico deveria ser 100 (%).', v; end if;
    update produtos set custo_atual = 1 where id = cx;

    -- T3b: outra OP entrou DEPOIS e por acaso deixou o custo igual → não pode
    -- "restaurar" às cegas; tem que tirar só a parte desta OP pela conta inversa
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (cx, 100, 'em_producao') returning id into o3;
    perform concluir_ordem_producao(o3, 100, 'fisico', false);          -- 100@1 + 100@2 → 1,5
    k := k + 1; update movimentacoes_estoque set created_at = created_at + make_interval(secs => k) where referencia_tipo = 'ordem_producao' and referencia_id = o3;
    update produtos set custo_atual = 1.5 where id = ch;
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (cx, 100, 'em_producao') returning id into o4;
    perform concluir_ordem_producao(o4, 100, 'fisico', false);          -- + 100@1,5 → continua 1,5
    k := k + 1; update movimentacoes_estoque set created_at = created_at + make_interval(secs => k) where referencia_tipo = 'ordem_producao' and referencia_id = o4;
    update produtos set custo_atual = 2 where id = ch;
    j := estornar_ordem_producao(o3);
    select custo_atual into c from produtos where id = cx;
    if j -> 'custo' ->> 'acao' <> 'recalculado' or abs(c - 1.25) > 0.00001 then
      raise exception 'PARADO T3b: sem a OP o custo seria 1,25 (100@1 + 100@1,5) — veio % / %.', j -> 'custo' ->> 'acao', c;
    end if;
    perform estornar_ordem_producao(o4);
    select custo_atual into c from produtos where id = cx;
    if abs(c - 1) > 0.00001 then raise exception 'PARADO T3b: custo deveria voltar a 1 (%).', c; end if;
    update produtos set custo_atual = 1 where id = cx;

    -- T4: kit consumindo produto acabado do Físico (modo direto) e modo "da matéria-prima"
    select jsonb_object_agg(produto_id || '|' || local, quantidade) filter (where quantidade <> 0) into antes
      from estoque_saldos where produto_id in (ch, cx, kit);
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (kit, 5, 'em_producao') returning id into o5;
    perform concluir_ordem_producao(o5, 5, 'full_conta2', false);       -- -10 caixas do Físico, +5 kits no Full JG
    k := k + 1; update movimentacoes_estoque set created_at = created_at + make_interval(secs => k) where referencia_tipo = 'ordem_producao' and referencia_id = o5;
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (kit, 10, 'em_producao') returning id into o6;
    perform concluir_ordem_producao(o6, 10, 'fisico', true);            -- -20 chapas, +10 kits no Físico
    k := k + 1; update movimentacoes_estoque set created_at = created_at + make_interval(secs => k) where referencia_tipo = 'ordem_producao' and referencia_id = o6;
    perform estornar_ordem_producao(o6);
    perform estornar_ordem_producao(o5);
    select jsonb_object_agg(produto_id || '|' || local, quantidade) filter (where quantidade <> 0) into depois
      from estoque_saldos where produto_id in (ch, cx, kit);
    if antes is distinct from depois then raise exception 'PARADO T4: saldos do kit não voltaram: antes % depois %', antes, depois; end if;
    -- estornar na ordem inversa (o6 e depois o5) devolve o custo exato de antes das duas
    select custo_atual into c from produtos where id = kit;
    if c <> 0 then raise exception 'PARADO T4: custo do kit deveria voltar a 0 (%).', c; end if;

    -- T5: componente sem custo → a OP não mexeu no custo → estorno também não
    insert into produtos (sku_interno, nome, tipo, unidade_medida, custo_atual)
      values ('ZZTESTE8-CHAPA0', 'teste8 chapa sem custo', 'materia_prima', 'UN', 0) returning id into ch0;
    insert into produtos (sku_interno, nome, tipo, unidade_medida, custo_atual)
      values ('ZZTESTE8-CAIXA0', 'teste8 caixa com custo', 'produto_acabado', 'UN', 1.5) returning id into cx0;
    insert into ficha_tecnica_itens (produto_acabado_id, produto_materia_prima_id, quantidade_necessaria) values (cx0, ch0, 1);
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (cx0, 3, 'em_producao') returning id into o7;
    perform concluir_ordem_producao(o7, 3, 'fisico', false);
    k := k + 1; update movimentacoes_estoque set created_at = created_at + make_interval(secs => k) where referencia_tipo = 'ordem_producao' and referencia_id = o7;
    j := estornar_ordem_producao(o7);
    if j -> 'custo' ->> 'acao' <> 'mantido' then raise exception 'PARADO T5: esperado mantido (%).', j -> 'custo'; end if;
    select custo_atual into c from produtos where id = cx0;
    if c <> 1.5 then raise exception 'PARADO T5: custo mudou (%).', c; end if;

    -- T6: OP antiga (sem registro de custo) → estorna só quantidade
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (cx, 10, 'em_producao') returning id into o8;
    perform concluir_ordem_producao(o8, 10, 'fisico', false);
    k := k + 1; update movimentacoes_estoque set created_at = created_at + make_interval(secs => k) where referencia_tipo = 'ordem_producao' and referencia_id = o8;
    update ordens_producao set custo_produto_antes = null, custo_produto_depois = null,
                               saldo_produto_antes = null, custo_alterado_pela_op = null where id = o8;
    select custo_atual into v from produtos where id = cx;
    j := estornar_ordem_producao(o8);
    if j -> 'custo' ->> 'acao' <> 'mantido' or position('Confira' in j -> 'custo' ->> 'motivo') = 0 then
      raise exception 'PARADO T6: OP antiga deveria manter custo com aviso (%).', j -> 'custo';
    end if;
    select custo_atual into c from produtos where id = cx;
    if c <> v then raise exception 'PARADO T6: custo mudou em OP antiga.'; end if;
    select quantidade into v from estoque_saldos where produto_id = cx and local = 'fisico';
    if v <> 100 then raise exception 'PARADO T6: caixa físico deveria ser 100 (%).', v; end if;

    -- T7: OP não concluída / inexistente
    insert into ordens_producao (produto_acabado_id, quantidade_planejada, status) values (cx, 1, 'em_producao') returning id into o9;
    e := null;
    begin perform estornar_ordem_producao(o9); exception when raise_exception then e := sqlerrm; end;
    if e is null or e not like '%Só dá pra estornar OP concluída%' then raise exception 'PARADO T7: estornou OP em produção (%).', e; end if;
    delete from ordens_producao where id = o9;                            -- OP em produção continua podendo ser excluída
    e := null;
    begin perform estornar_ordem_producao(gen_random_uuid()); exception when raise_exception then e := sqlerrm; end;
    if e is null or e not like '%não encontrada%' then raise exception 'PARADO T7: OP inexistente (%).', e; end if;

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
         (select count(*) from ordens_producao) as n_ordens,
         (select count(*) from ordens_producao where status = 'concluida') as n_concluidas
    into d;
  if row(a.fat, a.estoque, a.n_saldos, a.n_mov, a.n_prod, a.soma_custos, a.n_ficha, a.n_ordens, a.n_concluidas)
     is distinct from row(d.fat, d.estoque, d.n_saldos, d.n_mov, d.n_prod, d.soma_custos, d.n_ficha, d.n_ordens, d.n_concluidas) then
    raise exception 'PARADO: algo mudou além das funções. Nada foi aplicado.';
  end if;
end $$;

commit;

select 'ok — estorno de OP pronto; teste passou; nada de dado mudou' as status,
       (select count(*) from ordens_producao where status = 'concluida') as ops_concluidas;
