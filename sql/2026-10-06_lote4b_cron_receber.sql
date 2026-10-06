-- ============================================================
-- ERP E-Factory — LOTE 4b — agendamento do Contas a receber
-- A cada 15 minutos chama a Edge Function ml-sync-receber, que:
--   • lê as vendas novas do ML (pagamentos, liberação),
--   • reatualiza as que ainda não liberaram (a data do ML muda depois da entrega),
--   • registra cancelamentos do ML (tira do faturamento).
-- Cada rodada pega no máximo 40 vendas (fila controlada pelo banco).
-- ============================================================
select cron.unschedule('sync-receber') where exists (select 1 from cron.job where jobname = 'sync-receber');

select cron.schedule(
  'sync-receber',
  '*/15 * * * *',
  $$
  select net.http_post(
    url     := 'https://jrkuzyhobgzhjjyblmed.supabase.co/functions/v1/ml-sync-receber?limite=40',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body    := '{}'::jsonb,
    timeout_milliseconds := 60000
  ) as request_id;
  $$
);

select jobname, schedule, active from cron.job where jobname = 'sync-receber';
