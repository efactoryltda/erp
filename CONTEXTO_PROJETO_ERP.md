
# ERP E-Factory — Resumo do Projeto

> Documento de contexto. Cole isso no "Project knowledge" de um Claude Project
> pra qualquer chat novo já nascer sabendo do estado atual do projeto.
> Atualize este arquivo de vez em quando (peça pro Claude regenerar) conforme
> o sistema evoluir. **Última atualização: 2026-10-06** (Lote 4 — Contas a
> receber e cancelamentos do ML — ver seção "Contas a receber (Lote 4)").

## Visão geral

ERP customizado para a **E-Factory Group Ltda** (fabricante de caixas de
papelão, etiquetas térmicas e sacos de envio, Ribeirão Preto/SP), construído
do zero em HTML/JS puro (sem framework, sem build step) + Supabase (Postgres)
como backend, substituindo o Tiny ERP — exceto a emissão de nota fiscal, que
continua sendo feita pelo Tiny.

Operação: 3 contas de Mercado Livre + loja física. Sócios: João Gabriel (JG),
Gustavo Baruffi, e outro(s). Dono do projeto não sabe programar — todo o
código é escrito e mantido pelo Claude, com o dono fazendo apenas
copiar/colar e cliques guiados passo a passo.

## Onde está cada coisa

- **Frontend**: um único arquivo `index.html` (autocontido: HTML+CSS+JS
  inline), hospedado no **GitHub Pages** a partir da branch `main` do
  repositório `efactoryltda/erp` (deploy automático a cada commit, ~1-2 min).
  Endereço de produção: **https://efactoryltda.github.io/erp/**. Edição de
  textos simples pode ser feita direto no GitHub, sem precisar do Claude.
- **Netlify foi aposentado** — nada do projeto usa mais Netlify.
- **Homolog**: a branch `homolog` existe no GitHub, mas **não tem endereço
  publicado** (o GitHub Pages publica só a `main`). Em 2026-10-05 o dono
  decidiu publicar as mudanças **direto em produção** (`main`). Padrão
  adotado: o Claude prepara cada lote numa branch própria
  (`lote1-correcoes`, `lote2-autocomplete`, `lote3-liquido`…), o dono roda
  o SQL/Edge Functions primeiro, e só depois o Claude envia o `index.html`
  pra `main`. Reverter = um commit de volta na `main`.
- **Backend**: **Supabase** (projeto `jrkuzyhobgzhjjyblmed`), Postgres +
  Edge Functions (Deno/TypeScript).
- **Fiscal**: continua no **Tiny ERP** (não integrado ainda ao novo sistema).
- **Histórico de SQL no repositório**: `sql/historico_completo.sql` (até a
  fundação/integração ML) + um arquivo por lote em `sql/` (ex:
  `sql/2026-10-05_lote1_peso_sku.sql`). O banco real tem mais objetos do que
  o histórico do repositório mostra (Ordem de Compra, dashboard etc.) — antes
  de alterar funções existentes, conferir a definição real no banco.

## Arquitetura de dados (tabelas principais)

- `produtos` — cadastro único (matéria-prima e produto acabado juntos,
  campo `tipo`). Tem `sku_interno` (único, obrigatório) e `sku_ml`
  (opcional, só quando o SKU do Mercado Livre diverge do interno).
  **Desde 2026-10-05**: `peso_kg` é `numeric(14,5)` (5 casas decimais) e
  existe `skus_alternativos text[]` — SKUs antigos/alternativos do ML
  (ex: SKU que o anúncio usava antes de ser renomeado), editável na aba
  Produtos e usado no vínculo pedido ↔ produto.
- `ficha_tecnica_itens` — BOM: quanto de cada matéria-prima um produto
  acabado consome.
- `estoque_saldos` — saldo atual por produto e por **local**: `fisico`,
  `materia_prima`, `full_conta1` (E-Factory), `full_conta2` (JG),
  `full_conta3` (Gustavo Baruffi). *(local "full" genérico é legado, não
  usar mais)*
- `movimentacoes_estoque` — histórico de toda movimentação (auditoria).
- `ordens_producao` — ordens de produção; ao concluir, baixa matéria-prima e
  gera produto acabado automaticamente (função `concluir_ordem_producao`).
- `clientes` — **existe no schema mas não é usada** (pedido guarda só nome
  avulso em texto). Pendência conhecida, ver seção Pendências.
- `pedidos_venda` / `pedido_itens` — pedidos de venda (ML automático ou loja
  física manual). `canal` identifica de onde veio (`ml_conta1/2/3`,
  `loja_fisica`). `ml_order_id` evita duplicar pedido importado.
  `pedido_itens.produto_id` é nullable — quando o SKU do pedido ML não bate
  com nenhum produto cadastrado, o item entra mesmo assim com
  `sku_ml_item` preenchido, pra revisão manual. `data_pedido` é
  `timestamptz`. **Desde 2026-10-05**:
  - `pedido_itens.ml_item_id` — ID do anúncio (MLB…) do item do pedido.
  - `pedido_itens.estoque_baixado` (boolean) — se a baixa de estoque desse
    item realmente aconteceu. Itens que entraram sem produto ficam `false`
    e continuam `false` mesmo se forem revinculados depois (não baixa
    estoque retroativo, pra não contar em dobro — o Full já é corrigido
    pela sincronização). Cancelar/excluir pedido só devolve estoque de
    itens com `estoque_baixado = true`.
  - `pedidos_venda.valor_liquido`, `liquido_tarifa_ml`,
    `liquido_frete_vendedor`, `liquido_taxas_mp`, `liquido_status`
    (`ok` | `estornado` | `reembolso_parcial` | `pendente` |
    `sem_pagamento` | `erro`), `liquido_atualizado_em` — valor líquido do
    ML (o que entra de fato), **ao lado** do faturamento. `valor_total`
    (faturamento/bruto) **não muda**. Ver nota técnica "Valor líquido do
    Mercado Livre".
- `integracoes_ml` — token de acesso de cada conta ML conectada. **Sem
  policy de acesso pra anon/authenticated de propósito** (só Edge Functions
  com service_role acessam — dados sensíveis).
- `produto_anuncios_ml` — mapeia cada produto ao ID do anúncio (`MLB...` ou
  `MLBU...`) em cada conta. Usado na sincronização de estoque Full e, desde
  2026-10-05, também como último recurso pra achar o produto de um item de
  pedido (pelo ID do anúncio). Em 2026-10-05 todos os anúncios cadastrados
  eram formato `MLB` (26 na conta 1, 7 na conta 2, 9 na conta 3).
- `ml_ads_metricas_diarias` — uma linha por campanha + conta + dia, com as
  métricas de Product Ads (impressões, cliques, custo, ACOS, ROAS, vendas
  diretas/indiretas/totais) já em colunas tipadas, mais a resposta bruta da
  API em `metrics_raw` (jsonb) como backup. `integracoes_ml` ganhou as
  colunas `ml_advertiser_id` e `ml_advertiser_site_id` (IDs do Mercado Ads,
  diferentes do `ml_user_id`, buscados e cacheados na primeira sincronização
  de cada conta).
- `ml_perguntas_abertas` — "retrato atual" das perguntas SEM RESPOSTA de
  cada conta (canal, question_id, item_id, produto_id, texto, status,
  comprador_id, data_pergunta). A cada sincronização a tabela é atualizada
  pra bater com a realidade: pergunta respondida (ou anúncio fechado) é
  removida automaticamente (mesmo padrão de reconciliação usado no estoque
  Full). Não guarda histórico de perguntas já respondidas — só o que está
  em aberto agora. É lida e respondida direto na aba **Gestão de Contas**
  do `index.html` (ver seção "Módulos construídos").
- `ml_promocoes_ativas` — "retrato atual" das promoções ATIVAS (status
  `started`) de cada anúncio das 3 contas (canal, item_id, produto_id,
  promotion_id, tipo, nome, status, preco_promocional, preco_original,
  data_inicio, data_fim). A cada sincronização a tabela de cada conta é
  refeita do zero com o que está ativo agora — promoção que terminou ou
  anúncio sem nenhuma promoção some da lista automaticamente (mesmo padrão
  de "retrato atual" das outras tabelas). É lida na aba **Gestão de
  Contas** do `index.html` (ver seção "Módulos construídos"). Criada em
  2026-09-06, ainda pendente de deploy (ver Pendências).
- `ml_anuncios_metricas` — **histórico** (uma linha por anúncio + dia, NÃO
  é "retrato atual" que se apaga) com visitas, nota de qualidade da
  publicação (`quality_score`, `quality_level`, `quality_pendencias` —
  lista das melhorias pendentes em texto), nota média de avaliações,
  e status de concorrência de preço (só relevante pra anúncios em
  Catálogo — `eh_catalogo=false` pros outros, campo `price_to_win` fica
  null). Criada em 2026-09-06, ainda pendente de deploy (ver Pendências).
  `produto_id` é `on delete set null` desde a criação.
- `ml_analises` — guarda cada análise gerada pelo **Gestor de Contas
  (IA)** (`tipo`: diaria/semanal/mensal, `periodo_inicio`, `periodo_fim`,
  `conteudo` — o texto da análise em português gerado pela IA —,
  `dados_brutos` — jsonb com os números crus usados, pra auditoria).
  Histórico completo, nunca se apaga sozinha. RLS **só permite leitura**
  pra anon/authenticated — só a Edge Function (service_role) escreve, pra
  ninguém conseguir fabricar uma "análise da IA" falsa direto do
  navegador. Criada em 2026-09-06, ainda pendente de deploy (ver
  Pendências).
- Ordem de Compra (`ordens_compra`, `ordem_compra_itens`, views
  `vw_ordens_compra_resumo`, `vw_oc_itens`, `vw_custo_ficha`) — módulo de
  Compras (aba "Compras"), no ar desde 2026-09-28. A view `vw_oc_itens`
  depende de `produtos.peso_kg` (por isso a mudança de tipo do peso em
  2026-10-05 recriou essa view com a mesma definição/opções/permissões).

## Funções do banco (RPC)

- `concluir_ordem_producao` — baixa matéria-prima, gera produto acabado,
  calcula custo.
- `criar_pedido_venda` / `cancelar_pedido_venda` / `excluir_pedido_venda` —
  ciclo de vida do pedido, com baixa/devolução de estoque automática.
  **Desde 2026-10-05** cancelar/excluir só devolvem estoque dos itens com
  produto e `estoque_baixado = true` (antes, cancelar um pedido com item
  sem produto dava erro).
- `excluir_produto` — exclusão em cascata cuidadosa: bloqueia se o produto
  está em pedido de venda, ordem de produção, ou é matéria-prima usada na
  ficha técnica de outro produto (evita apagar relação escondida). Front-end
  exige digitar o SKU pra confirmar (proteção contra clique acidental de
  sócio).
- `transferir_estoque` — move estoque entre locais (ex: Físico → Full de
  uma conta), registrando os dois lados no histórico.
- `listar_integracoes_ml` — expõe só status de conexão (nunca os tokens).
- `dashboard_faturamento` (criada em 2026-09-23) — calcula faturamento
  hoje/mês/ano, pedidos no mês, e faturamento por canal (mês atual) direto
  no banco via `sum(...) filter (...)`, evitando o teto de ~1000 linhas
  por consulta do Supabase. Ver nota técnica "Faturamento do Dashboard"
  abaixo. `security definer`, `stable`, liberada pra `anon, authenticated`.
- `resumo_vendas_filtro(p_inicio, p_fim, p_canal)` — totais da lista de
  pedidos (total, confirmados, faturamento) com os filtros de data/canal.
- **Novas em 2026-10-05:**
  - `encontrar_produto_por_sku(p_sku, p_item_id)` — acha o produto de um
    item do ML, ignorando maiúsculas/espaços, nesta ordem: SKU do ML → SKU
    interno → SKUs alternativos → ID do anúncio em `produto_anuncios_ml`.
    Se achar mais de um produto no mesmo passo, não chuta (devolve vazio).
    Usada pelo `ml-webhook` e pelo revínculo.
  - `revincular_itens_sem_produto()` — liga ao produto os itens que estão
    sem produto; **não mexe em estoque**. Botão "Revincular itens sem
    produto" na aba Vendas. Devolve `{vinculados, ainda_sem_produto}`.
  - `filtrar_pedidos_venda(p_inicio, p_fim, p_canal, p_produto, p_texto)` —
    base única de filtro de pedidos (data, canal, produto, e texto em
    cliente / nº do pedido ML / SKU / nome do produto). `security invoker`.
  - `listar_pedidos_filtro_ids(...)` — IDs da página atual com esse filtro.
  - `resumo_vendas_filtro_v2(...)` — mesmos totais da
    `resumo_vendas_filtro`, mas aceitando produto/texto. O SQL de criação
    conferiu, em 6 combinações de data/canal, que sem produto/texto ela dá
    exatamente os mesmos números da função original. O front só usa a v2
    quando há filtro de produto/texto; sem isso, usa a consulta original.
  - `resumo_liquido_filtro(...)` — total do valor líquido com os mesmos
    filtros (líquido, vendas com líquido, vendas ML ainda sem líquido,
    bruto das que têm líquido).

## Edge Functions (Supabase, Deno)

Todas com **"Verify JWT" desligado** (obrigatório, senão o Mercado Livre não
consegue chamar — não tem crachá de autenticação Supabase). Esse toggle às
vezes volta a ligar sozinho após redeploy, checar sempre.

- `ml-oauth-callback` — recebe o retorno do login OAuth de cada conta,
  troca código por token, salva em `integracoes_ml` (busca e grava também o
  `ml_nickname` da conta pra identificação visual).
- `ml-webhook` — recebe aviso de pedido novo (tópico `orders_v2`), busca
  detalhes do pedido, identifica se é Full (checa `logistic_type` do
  shipping) ou Físico, casa os itens por SKU, cria o pedido automaticamente
  com baixa de estoque. **Desde 2026-10-05**: casa os itens via RPC
  `encontrar_produto_por_sku` (SKU, SKU alternativo ou ID do anúncio),
  grava `ml_item_id` e `estoque_baixado`, e calcula o **valor líquido** do
  pedido novo (via Mercado Pago). Quando chega aviso de um pedido que já
  existe, só recalcula o líquido — e só pra pedidos importados depois do
  Lote 3 (`liquido_status` preenchido); pedidos antigos não são tocados.
- `ml-sync-liquido` (**nova em 2026-10-05**) — preenche o valor líquido de
  vendas ML que ainda não têm. Só grava as colunas de líquido (nunca
  faturamento, estoque ou status). Dois modos:
  - automático (`?dias=3`, chamado ao abrir o ERP): só re-tenta vendas que
    o webhook já tentou calcular e ficaram pendentes/erro;
  - **backfill** (`?desde=AAAA-MM-DD&execucao=<ISO>`): botão "Preencher
    líquido das vendas antigas" na aba Integrações, com confirmação e botão
    "Parar". **Só rodar com aprovação do dono** — em 2026-10-05 decidido
    esperar a primeira venda nova pra comparar com o "Você recebe" do ML.
- `ml-sync-full-stock` — consulta o estoque Full real de cada anúncio
  cadastrado em `produto_anuncios_ml` e corrige o saldo do ERP pra bater com
  o Mercado Livre. Suporta os dois formatos de anúncio (ver nota técnica
  abaixo). **Precisa de CORS habilitado**
  (`Access-Control-Allow-Origin`) porque é chamada via `fetch()` direto do
  navegador, diferente das outras funções que o ML chama. Desde 2026-09-05
  também é chamada automaticamente todo dia às 05:00 (horário de Brasília)
  por um job do `pg_cron` (`sync-full-diario` — script em
  `sql/011_cron_sync_full_stock.sql`), usando `timeout_milliseconds := 30000`
  na chamada via `net.http_post` (o padrão do pg_net, 5s, não é suficiente
  pra percorrer os anúncios das 3 contas). O botão manual "Sincronizar Full
  agora" continua funcionando normalmente também.
- `ml-sync-ads-metricas` — busca (e cacheia) o `advertiser_id`/`site_id` de
  cada conta e sincroniza as métricas diárias das campanhas de Product Ads
  em `ml_ads_metricas_diarias`. Também chamada automaticamente todo dia às
  05:10 (horário de Brasília) por um job do `pg_cron`
  (`sync-ads-diario` — script em `sql/013_cron_sync_ads_metricas.sql`),
  com `timeout_milliseconds := 30000` pelo mesmo motivo do Full. Confirmada
  funcionando em 2026-09-06 (números batendo com o Mercado Ads nas 3
  contas). Botão manual "Sincronizar Ads agora" no `index.html`, ao lado do
  de Full. Ver nota técnica abaixo sobre o endpoint (documentação oficial é
  difícil de acessar e tem endpoints antigos descontinuados).
- `ml-sync-perguntas` — busca as perguntas com `status=UNANSWERED` de cada
  conta (paginando por `total`/`limit`/`offset`), liga cada uma ao produto
  interno via `produto_anuncios_ml`, grava/atualiza em
  `ml_perguntas_abertas` e remove as que não estão mais em aberto. Botão
  manual "Sincronizar Perguntas agora" no `index.html`, logo abaixo do de
  Ads (mesmo card "Estoque Full"). Confirmada funcionando em 2026-09-06
  (13 perguntas em aberto encontradas nas 3 contas). Desde 2026-09-06
  também é chamada automaticamente todo dia às 05:20 (horário de Brasília)
  por um job do `pg_cron` (`sync-perguntas-diario` — script em
  `sql/015_cron_sync_perguntas.sql`), confirmado funcionando pelo dono.
  **Desde 2026-10-05** também é chamada pela aba Gestão de Contas: ao
  entrar no ERP, ao abrir a aba (no máximo a cada 5 min) e no botão
  "Atualizar lista" (antes esse botão só relia o banco).
- `ml-responder-pergunta` — recebe `{canal, question_id, texto}` do botão
  "Responder" da aba Gestão de Contas, pega o token válido da conta (com
  renovação automática, mesmo padrão das outras funções), chama
  `POST /answers` no Mercado Livre e, se der certo, remove a pergunta de
  `ml_perguntas_abertas` (ela já não está mais em aberto). Erro do Mercado
  Livre ou de token vem de volta como `{ok:false, erro}` pro front-end
  mostrar. **Confirmado funcionando de ponta a ponta em 2026-09-06**
  (deployada e respondendo perguntas de verdade — ver gotcha do escopo
  OAuth abaixo).
- `ml-sync-promocoes` (código pronto em 2026-09-06, **ainda não deployada**
  — ver Pendências) — pra cada anúncio de `produto_anuncios_ml`, consulta
  `GET /seller-promotions/items/{item_id}?app_version=v2` (retorna todas as
  promoções do item) e filtra as com `status === 'started'` (ativas agora).
  A cada rodada, refaz do zero a tabela `ml_promocoes_ativas` daquela conta
  com o que está ativo (mesmo padrão de "retrato atual"). Botão manual
  "Sincronizar Promoções agora" já colado no `index.html` (mesmo card
  "Estoque Full", abaixo do de Perguntas). **Exige a permissão funcional
  "Promoções, cupons e descontos"** habilitada no app do Mercado Livre Devs
  Center — ver nota técnica e gotcha abaixo.
- `ml-sync-anuncios-metricas` (código pronto em 2026-09-06, **ainda não
  deployada** — ver Pendências) — pra cada anúncio de
  `produto_anuncios_ml`, consulta em paralelo 4 endpoints (visitas,
  qualidade, avaliações, concorrência de preço — ver nota técnica abaixo)
  e grava/atualiza uma linha do dia em `ml_anuncios_metricas` (upsert por
  `canal,item_id,data` — roda de novo no mesmo dia sem duplicar). Cada
  consulta falha de forma independente (fica `null`) sem travar as outras
  — ex: anúncio sem avaliação ainda, ou fora do Catálogo. Botão manual
  "Sincronizar Métricas de Anúncios agora" já colado no `index.html`
  (mesmo card "Estoque Full"). Alimenta o Gestor de Contas (IA) abaixo.
- `ml-analise-ia` (código pronto em 2026-09-06, **ainda não deployada** —
  ver Pendências) — o **Gestor de Contas (IA)**: recebe `{tipo: 'diaria'
  | 'semanal' | 'mensal'}`, calcula o período (diária=ontem, semanal=
  últimos 7 dias, mensal=últimos 30 dias), reúne em paralelo os 6 domínios
  de dados das 3 contas (vendas, estoque **unificado** Full+Físico,
  anúncios, ads, promoções, perguntas), monta um prompt e chama a
  **Claude API** (`model: claude-sonnet-5`) pra gerar uma análise em
  português com insights e sugestões práticas, e grava o resultado em
  `ml_analises` (upsert por `tipo,periodo_inicio,periodo_fim`). **Esse
  agente só analisa e sugere — ele nunca age sozinho** (não pausa
  anúncio, não ativa promoção, não muda nada): decisão explícita do dono
  em 2026-09-06, ver seção "Gestor de Contas (IA)" abaixo pro escopo
  completo combinado. Precisa do segredo `ANTHROPIC_API_KEY` configurado
  na Edge Function (ver Credenciais). **Correção 2026-09-XX**: a seção
  "Anúncios" da análise sempre vinha vazia em qualquer período —
  `buscarAnuncios()` usava o mesmo corte "termina ontem" das outras
  buscas, mas `ml_anuncios_metricas` só tinha dados de hoje (sync manual)
  na época do teste, que ficava fora de qualquer período. Corrigido
  estendendo o fim da busca de anúncios até hoje (é uma métrica de estado
  atual, como Promoções/Perguntas, não um fluxo estritamente limitado ao
  período como vendas/ads).

### Nota técnica: dois formatos de anúncio ML

- `MLBU...` (user_product_id) → `GET /user-products/{id}/stock`, campo
  `locations[].type === 'meli_facility'`.
- `MLB...` (item clássico) → dois passos: `GET /items/{id}` pra pegar
  `inventory_id`, depois `GET /inventories/{inventory_id}/stock/fulfillment`,
  campo `available_quantity`.

A função detecta automaticamente pelo prefixo do ID.

### Nota técnica: Valor líquido do Mercado Livre (validado em 2026-10-05)

- O ERP importa o **bruto** (`valor_total` = Σ preço unitário × quantidade;
  frete e taxas ficam 0). Isso continua sendo o **faturamento**.
- O **líquido** vem do pagamento no **Mercado Pago**:
  `GET https://api.mercadopago.com/v1/payments/{payment_id}` com o **mesmo
  token do ML** (testado: HTTP 200 nas 3 contas). `payment_id` vem de
  `order.payments[].id`. Campo: `transaction_details.net_received_amount`.
- Detalhamento em `charges_details[]` (só os com `accounts.from =
  'collector'`, valor = `amounts.original − amounts.refunded`):
  `type = 'shipping'` (`shp_fulfillment`, `shp_cross_docking`…) → frete
  pago pelo vendedor; nome `ml_*` (`ml_sale_fee`) → tarifa ML; demais
  (`mp_processing_fee`, `mp_financing_1x_fee`) → taxas Mercado Pago.
- Conferido em 9 pedidos reais: líquido + descontos = bruto, centavo a
  centavo (ex: 59,75 − 6,81 − 9,75 − 0,06 = 43,13).
- **Não usar `order_items[].sale_fee`** pra tarifa: diverge do cobrado de
  fato (ex: 6,87 no pedido vs 6,81 no pagamento).
- `/orders/{id}/discounts` traz o desconto bancado pelo vendedor (404
  quando não há desconto); `/shipments/{id}/costs` traz `senders[].cost`.
  Não são necessários pro líquido (já embutido no Mercado Pago).
- Pagamento `refunded/cancelled/charged_back/rejected` → líquido 0
  (`estornado`). Pagamento ainda não aprovado → fica sem líquido
  (`pendente`) e é tentado de novo depois. O campo `net_received_amount`
  continua preenchido mesmo em pagamento estornado — por isso a regra
  olha o `status`.
- SKU no pedido: `order_items[].item.seller_sku` vem preenchido nas 3
  contas (ex: `ROLO200`, `FITAKINESIO`); `user_product_id` e
  `variation_id` vieram nulos nos testes.

### Nota técnica: agendamento com pg_cron + pg_net

- `pg_cron` **não é relocável** — não force `with schema extensions` na
  criação da extensão (`create extension pg_cron;` sem especificar schema),
  senão o comando falha silenciosamente sem travar o resto do script.
- As tabelas de resposta do `pg_net` ficam no schema `net` mesmo
  (`net._http_response`, `net.http_request_queue`), não em
  `extensions.net`.
- O timeout padrão do `net.http_post` é só 5000ms — qualquer Edge Function
  que demore mais que isso (como a `ml-sync-full-stock`, que percorre vários
  anúncios) precisa de `timeout_milliseconds` explícito e maior.

### Nota técnica: API do Mercado Ads (Product Ads)

- Documentação oficial (`developers.mercadolivre.com.br`) bloqueia acesso
  automatizado (fetch direto retorna 403) — só dá pra consultar abrindo no
  navegador de verdade. Página certa (o slug "óbvio" `product-ads-leitura`
  não existe/redireciona): **Product Ads para Catálogo e User Products**,
  `pt_br/product-ads-para-catalogo-e-user-products-leitura`.
- Muitos endpoints antigos de Product Ads foram **descontinuados em
  27/05/2026** (retornam 404 "no static resource"), incluindo os que
  pareciam óbvios pelo nome: `GET /advertising/advertisers/$ADVERTISER_ID/product_ads/campaigns`
  e `GET /advertising/product_ads/campaigns/$CAMPAIGN_ID`. Só os endpoints
  publicados na documentação atual têm suporte.
- Endpoint atual (o que a `ml-sync-ads-metricas` usa) pra listar campanhas
  com métricas:
  `GET /advertising/$ADVERTISER_SITE_ID/advertisers/$ADVERTISER_ID/product_ads/campaigns/search`
  — repare no `$ADVERTISER_SITE_ID` (ex: `MLB`) logo depois de
  `/advertising/`, antes de `/advertisers/`; sem ele dá 404 igual aos
  endpoints descontinuados.
- Header obrigatório: `api-version: 2` (além do `Authorization: Bearer`).
- `advertiser_id` **e** `site_id` vêm juntos na resposta de
  `GET /advertising/advertisers?product_id=PADS` (esse endpoint aceita
  qualquer valor de `Api-Version`, não é estrito feito o de campanhas).
- Parâmetros da busca de campanhas: `date_from`/`date_to` (obrigatórios se
  pedir métricas), `metrics` (lista separada por vírgula — ver a função
  pra lista completa aceita), `limit`/`offset`, `metrics_summary` (default
  false). Sem `aggregation_type=DAILY`, a métrica vem agregada por
  campanha no período pedido — como a sync roda com `date_from = date_to =
  ontem`, isso já dá o valor diário por campanha sem precisar desse
  parâmetro.

### Nota técnica: API de Perguntas e Respostas do ML

- Endpoint: `GET https://api.mercadolibre.com/questions/search?seller_id=$SELLER_ID&api_version=4`,
  auth padrão `Authorization: Bearer` (sem header especial, diferente do
  Ads). Filtro usado: `status=UNANSWERED`. Paginação por `total`/`limit`/
  `offset` no corpo da resposta.
- `seller_id` = o `ml_user_id` que já fica salvo em `integracoes_ml` desde
  o OAuth — não precisa de nenhuma busca extra (diferente do
  `advertiser_id` do Ads).
- Responder uma pergunta: `POST /answers` com `{question_id, text}` — exige
  que o token tenha permissão de **escrita** (ver gotcha do escopo OAuth
  logo abaixo).
- Pergunta sem resposta há mais de 7 meses é apagada automaticamente pelo
  Mercado Livre.

### Nota técnica: API de Promoções do ML (`/seller-promotions`)

- Documentação oficial (mesmo bloqueio de fetch automatizado que a de Ads —
  só abre em navegador de verdade): **Central de promoções → Gerenciar
  promoções**, `pt_br/gerenciar-ofertas`.
- Endpoint usado pela `ml-sync-promocoes` — **consultar promoções de um
  item específico** (mais direto que teria que descobrir promoção por
  promoção):
  `GET https://api.mercadolibre.com/seller-promotions/items/$ITEM_ID?app_version=v2`
  — retorna um **array** com TODAS as promoções associadas àquele anúncio
  (candidatas, pendentes e ativas), cada uma com `type`, `status`, `price`,
  `original_price`, `start_date`/`finish_date` (nem toda promoção tem essas
  duas últimas), `name`. Filtramos só `status === 'started'` (ativa agora).
- Tipos de campanha possíveis no campo `type`: `DEAL`, `MARKETPLACE_CAMPAIGN`,
  `DOD` (oferta do dia), `LIGHTNING` (oferta relâmpago), `VOLUME` (desconto
  por quantidade), `PRICE_DISCOUNT` (desconto individual), `PRE_NEGOTIATED`,
  `SELLER_CAMPAIGN`, `SMART` (cofinanciada automatizada), `PRICE_MATCHING`,
  `UNHEALTHY_STOCK`, `SELLER_COUPON_CAMPAIGN`.
- **Exige a permissão funcional "Promoções, cupons e descontos"** habilitada
  no app do Mercado Livre Devs Center (dá acesso aos recursos `offers` e
  `deals`) — é uma permissão **separada** das já habilitadas (Vendas e
  envios, Publicação e sincronização, etc.). Como só fazemos `GET`, o
  escopo de **leitura** já é suficiente. **Como é permissão nova pro app,
  as 3 contas precisam ser reconectadas depois de habilitar** (ver gotcha
  do escopo OAuth abaixo — vale pra qualquer permissão nova).
- Não existe (pelo menos não documentado) um endpoint pra "listar todas as
  promoções ativas do vendedor de uma vez" de forma direta e barata — por
  isso a sincronização percorre item por item (mesmo padrão já usado pelo
  `ml-sync-full-stock`).

### Nota técnica: APIs de Métricas de Anúncio do ML (visitas, qualidade, avaliações, concorrência)

Documentação oficial com o mesmo bloqueio de fetch automatizado das
outras (só abre em navegador de verdade):

- **Visitas**: `GET /items/{ITEM_ID}/visits/time_window?last=1&unit=day`
  (doc `pt_br/recurso-visits` — o slug "óbvio" `pt_br/visitas` não existe,
  redireciona pra home). Retorna `total_visits` do último dia.
- **Qualidade da publicação**: `GET /item/{ITEM_ID}/performance` (anúncio
  clássico, prefixo `MLB...`) ou `GET /user-product/{ITEM_ID}/performance`
  (user product, prefixo `MLBU...`) — doc `pt_br/qualidade-das-publicacoes`.
  Substitui o endpoint antigo `/health`, **descontinuado em 07/02/2026**.
  Retorna `score` (0-100), `level`/`level_wording` (Básica/Satisfatória/
  Profissional), e uma árvore `buckets[].variables[].rules[]` — cada
  `rule` com `status` (PENDING/COMPLETED) e `wordings.title` descrevendo
  a melhoria específica (é esse texto que vira a lista de pendências que
  o Gestor de Contas (IA) usa pra sugerir o que melhorar em cada anúncio).
- **Avaliações**: `GET /reviews/item/{ITEM_ID}?limit=1` (doc
  `pt_br/opinioes-sobre-um-produto`) — mesmo com `limit=1`, o corpo da
  resposta já traz `rating_average`, `stars`, `rating_levels` e
  `paging.total` no nível raiz (não precisa paginar tudo). Sem permissão
  especial.
- **Concorrência de preço (Buy Box)**: `GET /items/{ITEM_ID}/price_to_win?version=v2`
  (doc `pt_br/concorrencia-em-catalogo` — o slug "óbvio" `pt_br/competicao`
  não existe). **Só funciona pra anúncios em modo Catálogo** — a maioria
  dos anúncios das 3 contas NÃO está em Catálogo (confirmado pelo dono em
  2026-09-06), então pra esses o endpoint retorna `reason:
  ["item_not_opted_in"]` e `price_to_win: null`. A função trata isso como
  "não aplicável" (`eh_catalogo=false`), nunca como erro. Quando aplica,
  retorna `status` (winning/competing/sharing_first_place/listed),
  `current_price`, `price_to_win`, `reason[]`.

### Nota técnica: integração com a Claude API (Anthropic) — Gestor de Contas (IA)

- Conta/chave em `platform.claude.com` → **Settings → API Keys**. A
  chave **nunca** é colada no chat com o Claude nem em nenhum arquivo do
  repositório — só como segredo direto no Supabase (Edge Functions →
  Secrets → `ANTHROPIC_API_KEY`), mesmo padrão já usado pra
  `ML_CLIENT_SECRET`.
- Endpoint: `POST https://api.anthropic.com/v1/messages`, headers
  `x-api-key`, `anthropic-version: 2023-06-01`, `content-type:
  application/json`; corpo `{model, max_tokens, system, messages}`.
- Model usado: `claude-sonnet-5`. Preço de referência (não cobrado do
  dono diretamente — é o custo de uso da API por trás da Edge Function):
  Claude Sonnet 5 = US$2/MTok entrada, US$10/MTok saída.

### Nota técnica: correção do Faturamento do Dashboard (2026-09-23)

O dono percebeu que o card "Faturamento hoje" do Dashboard mostrava um
valor **menor** do que somar manualmente os pedidos confirmados do dia.
Diagnóstico (seguindo o processo de dupla checagem/crosscheck antes de
implementar):

- Descartado: `data_pedido` não é uma coluna `date` simples que pudesse
  causar comparação de string errada — confirmado no schema
  (`sql/historico_completo.sql`) que é `timestamptz`.
- **Causa raiz confirmada**: `loadDashboard()` buscava TODOS os pedidos
  confirmados desde 1º de janeiro numa única consulta client-side, sem
  `.order()`/`.limit()`. O Supabase/PostgREST tem um teto padrão de
  **~1000 linhas por consulta** — com o volume atual (~270 pedidos
  confirmados/mês nas 3 contas, ou seja bem mais de 1000 desde janeiro),
  esse teto muito provavelmente já estava sendo ultrapassado, e o corte
  acontece **silenciosamente** (sem erro), sem garantia de que os pedidos
  de hoje estivessem no subconjunto retornado. Complicava ainda mais o
  fato de que o corte de "hoje"/"mês"/"ano" era feito com `new Date()` no
  navegador — dependente do fuso horário local de quem estivesse com o
  Dashboard aberto, não necessariamente o de Brasília.
- **Correção**: nova função `dashboard_faturamento()` (RPC no Postgres,
  ver seção "Funções do banco") que agrega tudo **dentro do banco** via
  `sum(...) filter (where ...)`, sem nenhum limite de linhas, e decide
  "hoje"/"mês"/"ano" sempre pelo horário de Brasília
  (`at time zone 'America/Sao_Paulo'`). O front-end (`loadDashboard()` em
  `index.html`) foi trocado pra só chamar
  `supabaseClient.rpc('dashboard_faturamento')` e ler o resultado, em vez
  de buscar e somar no navegador — mesmo padrão já usado em todo o resto
  do sistema (agregação/mutação sempre via função do banco).
- Script de deploy: `sql/022_dashboard_faturamento.sql` (cria/substitui a
  função + grant, e traz 2 queries de verificação: o resultado da própria
  função, e uma contagem total de pedidos confirmados desde janeiro pra
  confirmar se de fato passa de 1000). Front-end e SQL no ar (confirmado
  pelo dono em 2026-10-05).
- **Lição geral pra qualquer consulta futura no Dashboard/relatórios**:
  nunca somar/agregar no navegador buscando a tabela inteira sem
  `.order()` + `.limit()` explícito (ou, melhor ainda, sem uma função de
  agregação no banco) — o teto de linhas do Supabase corta
  silenciosamente, sem erro, e o resultado pode "parecer" certo mesmo
  estando incompleto.

### Gotcha importante: escopo OAuth fica fixo no token — mudar a permissão do app não atualiza contas já conectadas

Em 2026-09-06, ao testar o botão "Responder" pela primeira vez, deu
`Unauthorized`. Causa: as 3 contas foram conectadas via OAuth quando o app
do Mercado Livre Devs Center só tinha permissão de **Leitura**; o dono
mudou a permissão do app pra **Leitura e Escrita**, mas isso **não
atualiza os tokens já emitidos** — o escopo de um token OAuth é decidido
no momento da autorização, e a renovação automática via `refresh_token`
(usada em `getAccessToken()` de todas as Edge Functions) **reusa o mesmo
escopo antigo**, nunca herda uma permissão nova do app. **Resolvido**
reconectando (botão "Reconectar" na aba Integrações) as 3 contas, uma por
uma, gerando tokens novos já com o escopo de escrita. **Lição pra
qualquer permissão nova habilitada no app no futuro**: sempre reconectar
(reautorizar) todas as contas já ligadas — nunca basta mudar a permissão
do lado do Mercado Livre e esperar que o token existente reflita isso.
**Vale de novo agora pra promoções**: a permissão "Promoções, cupons e
descontos" é nova pro app, então as 3 contas precisam ser reconectadas
depois de habilitá-la, senão a Edge Function `ml-sync-promocoes` vai dar
erro de autorização nas 3 contas.

### Gotcha importante: como colar snippets de JS no `index.html`

Em 2026-09-06 o botão de Perguntas quebrou o site inteiro (caiu numa tela
de login que nunca saía) porque o snippet entregue envolvia o pedaço de JS
numa tag `<script>...</script>` só por clareza visual do arquivo — e o dono
colou isso literalmente dentro do `<script>` que já existia no
`index.html`, criando uma tag `<script>` aninhada. HTML não permite isso: o
parser fecha o script real no primeiro `</script>` que encontra (ainda que
seja o aninhado), e tudo que vem depois deixa de ser JS. O erro no console
era só `SyntaxError: Unexpected token '<'`, sem indicar a causa real.
**Lição pra próximos snippets**: nunca incluir as tags `<script>`/
`</script>` de novo num trecho que já vai ser colado dentro de um
`<script>` existente — mandar só o JS puro, deixando claríssimo que não é
pra copiar tag nenhuma. Debug de casos assim: baixar o `index.html` real
via `curl https://raw.githubusercontent.com/efactoryltda/erp/main/index.html`
(muito mais confiável que confiar em busca semântica desatualizada do
Project) e usar o Chrome (via `claude-in-chrome`, o dono já tem esse
navegador conectado) pra ler os erros de console (`read_console_messages`)
— a linha do erro aponta direto pro problema. A correção em si foi feita
com o dono direto no editor do GitHub (`Find`/`Replace` com Regexp
habilitado, usando `\n` pra casar quebra de linha), evitando reescrever o
arquivo inteiro.

### Aba "Gestão de Contas" (criada em 2026-09-06)

Primeira aba nova criada dentro da visão de longo prazo de "Gestão de
Contas" (que ainda vai ganhar histórico de análises diária/semanal/mensal
e várias outras seções no futuro). Tem hoje dois cards recolhíveis:

- **Perguntas em aberto**: lista cada pergunta das 3 contas (identificando
  a conta e o produto — ou avisa quando o SKU do anúncio não bate com
  nenhum produto cadastrado), com uma caixa de texto e botão "Responder"
  que chama a Edge Function `ml-responder-pergunta` e mostra na hora se deu
  certo (✅, remove o card da lista) ou deu erro (❌, mostra a mensagem,
  deixa tentar de novo). Botão "Atualizar lista" **busca no Mercado Livre
  (chama `ml-sync-perguntas`) e depois recarrega** a lista (desde
  2026-10-05; antes só relia `ml_perguntas_abertas`). A busca também roda
  ao entrar no ERP e ao abrir a aba (no máximo a cada 5 min). **Módulo
  confirmado funcionando de ponta a ponta pelo dono em 2026-09-06.**
- **Promoções ativas e vencendo** (criado em 2026-09-06): lista as
  promoções ativas das 3 contas, ordenadas pela data de término mais
  próxima, mostrando conta, tipo da campanha, produto (ou aviso de SKU não
  identificado), preço promocional vs. original, e a data de término em
  destaque vermelho quando falta 3 dias ou menos (⚠️ vencendo em breve).
  Botão "Atualizar lista" recarrega a leitura de `ml_promocoes_ativas`.
  **Front-end já no ar e confirmado funcionando** (renderiza o card, abre/
  fecha, e mostra corretamente a mensagem de erro enquanto a tabela não
  existe) — falta só o backend (tabela + Edge Function + agendamento),
  ver Pendências.

- **Gestor de Contas (IA)** (criado em 2026-09-06): terceiro card da
  aba. Escopo definido em conversa com o dono antes de construir (não foi
  direto pra implementação):
  - **Entrega**: card no ERP (não email/WhatsApp).
  - **Cadência**: diária + semanal + mensal, todas automáticas via
    pg_cron (sem intervenção manual, mas com botão "Gerar agora" pra
    forçar na hora).
  - **Interatividade**: só o relatório automático por enquanto — **sem
    chat** (pode virar um passo futuro, não nesta versão).
  - **Nível de autonomia — decisão importante**: o agente **só analisa e
    sugere, nunca age sozinho** — não pausa anúncio, não ativa/desativa
    promoção, não muda preço, nada. Decisão explícita do dono, escolhida
    entre as opções apresentadas.
  - **Visão**: consolidada das 3 contas + destaques por conta (nem tudo
    separado por conta, nem tudo 100% misturado).
  - **Estoque**: considera Full **e** Físico (Físico = o que alimenta
    Flex + Depósito ML) **juntos**, como um único risco de ruptura por
    produto — não precisa separar, por pedido explícito do dono.
  - **Anúncios**: novo tópico incluído a pedido do dono, cobrindo os 4
    sinais que ele escolheu (todos): visitas x conversão, qualidade da
    publicação, competitividade de preço (só Catálogo — a maioria dos
    anúncios não está, tratado como "não aplicável"), reputação e
    avaliações.
  - Interface: seletor Diária/Semanal/Mensal, um `<select>` de histórico
    (lê `ml_analises` por tipo, mais recente primeiro), área de texto com
    o conteúdo da análise, botão "Gerar agora" que chama `ml-analise-ia`
    na hora.
  - **Vínculo com produtos / longevidade**: reaproveita a mesma tabela
    `produto_anuncios_ml` já usada por Full/Perguntas/Promoções — nenhuma
    tabela de mapeamento nova. Todas as tabelas novas de análise
    (`ml_anuncios_metricas`) e as já existentes que referenciam produto
    (`ml_perguntas_abertas`, `ml_promocoes_ativas`) usam `produto_id ...
    on delete set null` — excluir um produto no ERP **nunca** trava por
    causa de uma linha de histórico/análise órfã (mantém o histórico, só
    perde o vínculo). `ml_analises` não referencia produto (é
    consolidada).
  - **Front-end já no ar e confirmado funcionando** (renderiza o card,
    abre/fecha, tabs Diária/Semanal/Mensal, mostra corretamente a
    mensagem de erro enquanto a tabela não existe) — falta só o backend,
    ver Pendências.

**Padrão de card recolhível (accordion), criado em 2026-09-06**: como a
aba vai crescer com várias seções, o card de Perguntas foi transformado no
primeiro "card recolhível" — um padrão genérico e reutilizável pra
qualquer card futuro dessa aba (o card de Promoções já nasceu usando esse
padrão). Estrutura: `<div class="card
collapsible-card" id="card-<key>">` com um `.collapsible-header` (clicável,
com `onclick="toggleCollapsible('<key>')"`) contendo um chevron
(`.collapsible-chevron`, gira 90° quando aberto), o título, e um badge
contador (`.badge-contador`, id `badge-<key>`) que fica com fundo/texto
vermelho (`.pendente`) quando há itens pendentes; o conteúdo fica dentro de
`.collapsible-content-wrap` > `.collapsible-content-inner` (animação via
CSS `grid-template-rows: 0fr → 1fr`, sem JS de altura). A função JS
genérica é `toggleCollapsible(key)` (só dá toggle na classe `.open` do
card) — qualquer card novo reaproveita o mesmo CSS/JS, só muda o `key` e o
conteúdo interno. O card de Perguntas usa `key = 'perguntas-abertas'`, o de
Promoções usa `key = 'promocoes-ativas'`; ambos começam **sempre recolhidos
por padrão**.

### Padrão de campo de busca com autocomplete (criado em 2026-10-05)

Função genérica `criarAutocomplete(select, {curto, placeholder})` no
`index.html`: transforma um `<select>` num campo de digitar com sugestões.
O `<select>` original continua existindo (escondido) e continua sendo a
"fonte da verdade" — o resto do sistema lê/escreve `.value` e escuta
`change` como antes. Busca ignora acentos/maiúsculas e aceita várias
palavras; setas + Enter; ao sair do campo com 1 sugestão só, escolhe ela;
`form.reset()` e atribuição de `.value` por código atualizam o campo
visível; `required` passa pro campo visível; recarregar as `<option>`
(MutationObserver) atualiza as sugestões. Opção de valor vazio vira o texto
de fundo (ex: "Todos"). Aplicado em: `v-item-produto`, `m-produto`,
`t-produto`, `f-acabado`, `f-materia`, `oc-i-produto`, `o-produto`,
`f-produto`, `f-canal`, `oc-filtro-status`. Os campos de produto agora
**começam em branco** (antes já vinha o 1º produto escolhido). Pra usar em
um campo novo: `criarAutocomplete(document.getElementById('id-do-select'))`.

### Gotcha importante: como aplicar edições grandes no `index.html` com segurança

Editar o arquivo inteiro ao vivo no editor do GitHub via Find/Replace
(mesmo em modo Regexp) é frágil pra edições grandes/múltiplos pontos —
já aconteceu de uma operação de Find/Replace corromper silenciosamente um
trecho não relacionado (um `id` de botão virou código JS literal), sem
nenhum erro visível, só descoberto depois com um `curl` fresco do arquivo
raw. **Técnica atual, mais segura, usada desde a aba Gestão de Contas**:

1. Baixar o `index.html` ao vivo (`curl raw.githubusercontent.com/.../index.html`).
2. Reconstruir o arquivo inteiro localmente com um script Python de
   substituição de string precisa, usando um `replace_once()` que garante
   (com `assert`) que cada âncora aparece exatamente 1 vez antes de
   substituir — nunca 0, nunca 2+.
3. Verificar a reconstrução: rodar `node --check` nos blocos `<script>`
   extraídos (garante que não quebrou sintaxe JS) e comparar contagem de
   `<div`/`</div>` antes/depois (garante que não desbalanceou HTML).
4. Aplicar o arquivo inteiro de uma vez no editor do GitHub — **não** via
   clipboard (o `navigator.clipboard.writeText()` trava indefinidamente
   quando chamado por automação, mesmo com a permissão do site já
   concedida — falta o "gesto de usuário" real que o Chrome exige; testado
   e confirmado que trava mesmo com `document.hasFocus()` true).
   Em vez disso, acessar direto a instância do CodeMirror 6 que o GitHub
   usa: `document.querySelector('.cm-content').cmTile.view` é a
   `EditorView`, e `view.dispatch({changes:{from:0, to:view.state.doc.length,
   insert: textoNovo}})` substitui o documento inteiro instantaneamente,
   sem precisar de clipboard nem de foco/gesto real. Depois só conferir
   que `view.state.doc.toString() === textoNovo` bate, clicar em "Commit
   changes..." e confirmar.
5. Verificar depois do commit: `curl` de novo o raw file e `diff` contra o
   arquivo local reconstruído (deve ser idêntico byte a byte), depois abrir
   o site ao vivo e checar `read_console_messages` (sem erros) + conferir
   visualmente a mudança.

**Atualização 2026-10-05**: quando a sessão do Claude tem acesso de
escrita ao repositório `efactoryltda/erp` (git push), o caminho preferido
é: clonar, editar localmente com `replace_once` + `node --check` + teste
num navegador automático (Playwright com Supabase simulado), commitar numa
branch do lote, e — depois que o dono confirmar que rodou o SQL/Edge
Functions — enviar pra `main` (conferindo antes que a `main` não andou:
`git merge-base --is-ancestor origin/main HEAD`) e checar que o deploy do
GitHub Pages terminou com sucesso.

### Gotcha importante: transferir o arquivo inteiro via base64 por chat é arriscado — prefira edição cirúrgica

Na edição do card recolhível de Perguntas (2026-09-06), a técnica de
transferir o arquivo inteiro em base64 (dividido em pedaços de ~20000
caracteres, remontados via `javascript_tool` no `window`) se mostrou
**não confiável**: mesmo quando o tamanho do pedaço batia exatamente (ex:
20000 caracteres), o *conteúdo* podia vir sutilmente corrompido (um
caractere trocado por outro em algum ponto do meio do blob) — porque
reproduzir uma string enorme e sem "sentido" (base64 não tem palavras,
só ruído) por geração de texto é propenso a erro, e um tamanho batendo não
garante que o conteúdo bate. Isso só foi pego porque cada pedaço foi
conferido com **SHA-256** contra o hash do arquivo original (`sha256sum`
local vs. `crypto.subtle.digest` no navegador) — sem essa checagem, o
arquivo teria sido commitado silenciosamente corrompido.

**Técnica corrigida, mais segura, adotada a partir daqui**: em vez de
reconstruir e transferir o arquivo inteiro, aplicar cada mudança como uma
edição cirúrgica diretamente na instância do CodeMirror do GitHub:

```js
const view = document.querySelector('.cm-content').cmTile.view;
function applyReplace(oldStr, newStr, label) {
  const text = view.state.doc.toString();
  const count = text.split(oldStr).length - 1;
  if (count !== 1) throw new Error(`[${label}] esperava 1 ocorrência, achou ${count}`);
  const idx = text.indexOf(oldStr);
  view.dispatch({changes: {from: idx, to: idx + oldStr.length, insert: newStr}});
}
```

Cada `oldStr`/`newStr` é curto (o mesmo par usado no script Python local
de `replace_once`), então o risco de erro de transcrição é muito menor, e
o próprio `count !== 1` já funciona como trava de segurança (se o texto
não bater exatamente com o que está ao vivo no editor, a função nem
tenta aplicar — falha alto e claro em vez de corromper). No final,
comparar `view.state.doc.toString()` (via SHA-256) contra o arquivo local
já verificado, garantindo bit a bit que o editor ficou idêntico ao
esperado antes de commitar. Use essa técnica cirúrgica como padrão pra
próximas edições — só cair pro "arquivo inteiro em base64" se for uma
reescrita tão grande/espalhada que não dá pra expressar como poucos pares
`oldStr`/`newStr` únicos.

**Reforço em 2026-09-06 (card de Promoções)**: pra evitar até o risco de
digitar errado um caractere acentuado/emoji dentro do próprio `oldStr`/
`newStr` na hora de montar a chamada do `javascript_tool`, os textos foram
gerados como strings **JSON-escapadas em ASCII puro** (`json.dumps(...,
ensure_ascii=True)` em Python — todo caractere não-ASCII vira `\uXXXX`),
eliminando qualquer ambiguidade de encoding na transcrição. A checagem
final por SHA-256 continua sendo a prova definitiva de que o resultado
bate exatamente com o esperado, independente de qualquer erro de digitação
no meio do processo (ou o hash bate, ou não bate — não existe meio-termo
"quase certo" que passe despercebido). **Confirmado de novo em 2026-09-23**
(correção do Faturamento do Dashboard): mesma técnica (curl do arquivo
vivo → replace único verificado em Python → payload JS ASCII → SHA-256
antes/depois/pós-commit), sem incidentes.

### Gotcha: aviso "Potential issue detected" (RLS) no SQL Editor do Supabase

Scripts que criam uma **tabela temporária** (`create temp table ... on
commit drop`, usada nos SQLs de lote pra tirar uma "foto" antes/depois e
conferir que nada mudou) disparam um aviso do Supabase dizendo que a tabela
não tem Row Level Security. É falso alarme: tabela temporária só existe
durante a execução e não é acessível pelo site. Clicar em **"Run without
RLS"** — não usar "Run and enable RLS" (modifica o script antes de rodar).

### Padrão dos SQLs de lote (adotado em 2026-10-05)

Cada SQL de alteração roda numa transação única (`begin … commit`) e
**se confere sozinho**, abortando tudo com uma mensagem "PARADO: …" se algo
não bater: (1) antes de substituir uma função existente, compara o corpo
atual (md5 sem espaços) com o esperado — se alguém mudou a função no banco
desde o histórico, para; (2) funções novas que espelham uma existente são
comparadas com a original em vários cenários; (3) mudanças que não podem
mexer no faturamento tiram uma foto dos totais antes/depois. O resultado
final do RUN mostra uma linha de conferência pro dono mandar de volta.

## Correções de 2026-10-05 (Lotes 1, 2 e 3)

Pedido do dono: 5 correções. Diagnóstico feito antes (SQL só leitura +
Edge Function temporária `ml-diagnostico` só leitura com 9 pedidos reais
das 3 contas). Tudo publicado em produção no mesmo dia.

- **Lote 1** (`sql/2026-10-05_lote1_peso_sku.sql`):
  1. **Peso com 5 casas** — `produtos.peso_kg` → `numeric(14,5)`; campo
     da tela com `step="0.00001"`.
  2. **"SKU não identificado"** — havia 1.213 itens de pedido sem produto.
     Causa principal: **pedidos que chegaram antes do produto ser
     cadastrado** (ex: TEKBOND5, FITAKINESIO, TEKBOND2 cadastrados em
     28/09) nunca eram religados; o casamento em si funcionava. Os outros
     285 itens usam **SKUs antigos que não existem mais no ERP**
     (KIT4ROLOETIQUETA200 153, ADESIVOACNE 84, ROLOETIQUET127 15,
     KIT4ETIQUETA127 8, ROLOETIQUETA200 6, KIT6ROLOETIQUETATERMICA127 6,
     KIT4ROLOETIQUETATÉRMICA127 5, 4ROLOETIQUETA200 4, KIT50CAIXAS191212 3,
     KIT25CAIXAS19X14X16 1). Correção: função `encontrar_produto_por_sku`,
     campo "SKUs antigos/alternativos (ML)" no produto, botão "Revincular
     itens sem produto" na aba Vendas (928 itens revinculáveis na hora),
     webhook usando a função nova, e regra `estoque_baixado` (revínculo não
     baixa estoque retroativo).
  3. **Perguntas não sincronizavam na Gestão de Contas** — o "Atualizar
     lista" só relia o banco. Agora chama `ml-sync-perguntas`.
- **Lote 2** (`sql/2026-10-05_lote2_filtro_pedidos.sql`):
  4. **Busca digitada com autocomplete** nos campos de produto e nos
     filtros (ver "Padrão de campo de busca com autocomplete"); filtro de
     pedidos ganhou **Produto** e **Cliente, nº do pedido ou SKU**; busca
     na tabela de Produtos (SKU, nome, SKU ML, SKUs alternativos) e no
     Saldo de estoque. Faturamento do filtro respeita os filtros novos.
- **Lote 3** (`sql/2026-10-05_lote3_valor_liquido.sql`):
  5. **Valor líquido do ML ao lado do faturamento** — colunas novas em
     `pedidos_venda`, coluna "Líquido" na lista de pedidos (tooltip com o
     detalhamento), linha "Líquido Mercado Livre" abaixo do faturamento do
     período, card "Valor líquido (Mercado Livre)" em Integrações com o
     botão de backfill. Faturamento intacto (conferido pelo SQL).

## Contas a receber (Lote 4 — 2026-10-05/06)

Aba **Contas a receber** (menu, logo abaixo de Vendas). Visão SEPARADA do
faturamento: o faturamento continua sendo `pedidos_venda.valor_total`.

- **Tabela `lancamentos_financeiros`** (`sql/2026-10-06_lote4_contas_receber.sql`):
  uma linha por **pagamento do ML** (origem `ml`, chave `ml_payment_id`), por
  **pedido do PDV/loja** (origem `pedido`, criada pelo trigger
  `trg_lancamento_pedido`) ou **lançamento manual** (origem `manual`:
  venda / aporte / outros, custo opcional). Campos separados pra evoluir pra
  DRE/contas a pagar: `natureza` (receber|pagar), bruto, tarifa, frete (já
  sem o que o comprador pagou), taxas, outros_ajustes, reembolsado, líquido,
  imposto (vazio por enquanto), custo_manual, `dados_ml` (jsonb de auditoria).
  RLS: só `authenticated` lê; pelo site só cria/edita/apaga lançamento manual
  e muda a data de pedido do PDV; linhas do ML só a Edge Function grava.
- **Data de liberação = a que o Mercado Pago informa** (`money_release_date`),
  sem calcular prazo. Enquanto pendente, o ML mostra ~28 dias, mas libera
  ANTES (logo depois da entrega) — por isso a sincronização reatualiza.
  Na tela aparece como "previsão ML". Parcelado: o ML libera de uma vez
  (`money_release_schema` sempre vazio — validado em 05/10).
- **Custo** (`vw_custo_unitario`): ficha técnica completa → custo da ficha
  (kit = soma dos componentes, todos os níveis, via `vw_custo_ficha`); ficha
  com componente sem custo → SEM CUSTO; sem ficha → `custo_atual` se > 0.
  Custo calculado AO VIVO (decisão do dono, enquanto os custos são preenchidos).
  Venda sem custo: aviso na tela e fica fora do lucro, mas soma no valor a
  receber. Lucro = líquido − custo (sem imposto). Pedido com 2+ pagamentos:
  custo dividido pelo bruto de cada pagamento. Aporte/outros: fora do lucro.
- **Status**: `a_receber`, `recebido`, `aguardando` (pagamento pendente),
  `estornado`. Pedido cancelado no ML conta como estornado mesmo antes de o MP
  estornar (Lote 4d, `sql/2026-10-06_lote4d_cancelado_estornado.sql`).
  PDV/manual: vira "recebido" quando passa a data.
- **Funções** (somam tudo no banco): `contas_receber_base` (base única de
  filtros), `contas_receber_listar` (paginada), `contas_receber_resumo`
  (cards), `contas_receber_mensal` (gráfico por mês de liberação × canal ×
  natureza). Filtros: período (`p_inicio`/`p_fim`), meses soltos (`p_meses`,
  Lote 4c), canais, status, texto.
- **Edge Function `ml-sync-receber`**: fila do banco (`receber_fila_sync`:
  vendas novas + não liberadas + liberadas há ≤30 dias, relidas a cada 6h),
  lê pedido + pagamentos no MP, grava as linhas, atualiza as colunas de
  líquido do Lote 3 com a MESMA conta e **registra cancelamento do ML**
  (`registrar_cancelamento_ml`): tira do faturamento; o estoque só volta se
  saiu do físico, o envio nunca saiu e o cancelamento é recente (≤3 dias);
  Full nunca (a sync do Full corrige). Agendada a cada 15 min (`sync-receber`,
  `sql/2026-10-06_lote4b_cron_receber.sql`, 40 vendas por rodada). Ao abrir a
  aba: 1 rodada leve; botão "Atualizar do Mercado Livre": até 5 rodadas.
- **Fórmula do líquido (corrigida no Lote 4, vale também pro Lote 3)**:
  frete do vendedor = cobrança de frete − `shipping_amount` (parte paga pelo
  comprador); taxas = taxas − créditos do comprador (ex: `financing_transfer`);
  líquido = `net_received_amount` − reembolsado + cobranças devolvidas. O MP
  NÃO atualiza o `net_received_amount` depois de reembolso.
- **`ml-webhook`**: pedido que já chega cancelado entra como cancelado e sem
  baixa de estoque; aviso de cancelamento de pedido existente →
  `registrar_cancelamento_ml`.
- **Backfill** rodado em 2026-10-06: 2.323 pedidos ML → 2.353 lançamentos;
  **119 vendas canceladas saíram do faturamento** (estoque não mexido).
- **Tela**: filtros (presets de período, meses soltos com busca digitada,
  canais e status em seleção múltipla com digitação, busca por texto), 4 cards
  (a receber, recebido, lucro, vendas sem custo), gráfico de barras
  empilhadas em SVG próprio (cor fixa por canal: Físico amarelo, ML 1 azul,
  ML 2 laranja, ML 3 verde-água, Loja online rosa, Outros violeta), tooltip,
  "Ver como tabela", checkbox "Lucro líquido", lista paginada com tooltip do
  detalhamento, lançamento manual e mudança de data de pedido do PDV.
  O layout de celular (abaixo de 760px o menu vira uma barra no topo) vale
  pro ERP todo.
- **Conferido em 06/10**: 23 de 26 pagamentos lidos ao vivo no MP batem
  centavo a centavo (dos 3 restantes: 1 cancelada já tratada pelo 4d e 2 com
  data mudada pelo ML ainda não relida); soma do gráfico = total do resumo;
  bruto dos lançamentos ML = faturamento ML (exceto 2 chargebacks, R$ 43,24);
  consultas em 160–350 ms com 2.369 lançamentos.

## Consumo próprio (Lote 5 — 2026-10-06)

Card **"Consumo próprio"** na aba Vendas (logo abaixo de "Registrar pedido").
Produto usado pela própria empresa — **não é venda**: não cria pedido, não
entra em faturamento, contas a receber nem lucro.
- Campos: produto (qualquer produto ATIVO, acabado ou matéria-prima — campo de
  texto com autocomplete), quantidade, data (padrão hoje, Brasília),
  observação. Mostra de qual estoque sai, o saldo atual e o saldo depois
  (avisa se vai ficar negativo — **saldo negativo é permitido**, decisão do dono).
- Estoque: produto acabado → **Físico**; matéria-prima → **Matéria-prima**
  (onde ela fica guardada). Nunca Full.
- Banco (`sql/2026-10-06_lote5a_consumo_proprio_tipo.sql` +
  `sql/2026-10-06_lote5b_consumo_proprio.sql`): tipo de movimentação novo
  `consumo_proprio`; colunas novas em `movimentacoes_estoque`:
  `custo_unitario` (custo do momento, via `vw_custo_unitario` — pra DRE),
  `usuario_email` (quem registrou), `data_referencia` (data informada).
  Funções `registrar_consumo_proprio` (baixa + movimentação numa operação só,
  sem risco de clique duplo errar o saldo), `desfazer_consumo_proprio`
  (devolve ao mesmo estoque com movimentação `referencia_tipo =
  'estorno_consumo_proprio'`; não deixa desfazer duas vezes; nada é apagado)
  e `listar_consumo_proprio` (últimos 30, com "desfeito"). Só `authenticated`.
- Kit consumido baixa o kit (não os componentes), igual venda.

## Produção em etapas (Lote 6 — 2026-10-06)

Ex: **Chapa → Chapa Cortada → Caixa** (rendimento 1:1 hoje; tamanhos que passam
por isso: 24x15x10, 19x12x12 — a automontável não —, 29x14x16). Os
**cadastros (chapas, cortadas, fichas) ficam com a equipe**; o sistema só foi
preparado (`sql/2026-10-06_lote6_producao_em_etapas.sql`).
- **Ficha técnica**: "Produto feito" aceita qualquer produto ativo, inclusive
  matéria-prima feita aqui (Chapa Cortada ← Chapa; Caixa ← Chapa Cortada).
  Trigger `trg_ficha_bloquear_ciclo` impede ficha em ciclo (A usa B que usa A).
- **Produção**: lista qualquer produto ativo com ficha. Destino automático pelo
  tipo — matéria-prima → estoque **Matéria-prima** (único destino, travado);
  produto acabado → Físico ou Full. Modo "Direto da matéria-prima" desce a ficha
  até a chapa (cortar e colar de uma vez, sem estoque intermediário).
- **Proteção de custo** em `concluir_ordem_producao`: se algum componente
  consumido tiver custo 0, a produção acontece mas o custo médio do produto
  feito NÃO muda (custo zero não contamina). A tela avisa antes de concluir.
  A função foi alterada só em 5 trechos (via replace verificado no próprio SQL);
  **ela está gravada no banco com quebra de linha Windows (\r\n)** — lembrar
  disso em alterações futuras por replace.
- **Atenção (custos)**: todas as chapas estão com custo 0. A Caixa D6 já está
  ligada à Chapa Cortada 24x15x10 → hoje D6 e Kit 4 Rolos 200 aparecem "sem
  custo". **Antes de ligar Caixa D3/D7 às cortadas, cadastrar o custo das
  chapas** (OC ou cadastro), senão Kit 6 Rolo 127 / Kit 6 Rolo 200 / Kit 8 Rolo
  200 também perdem o custo no lucro do contas a receber.

## Credenciais e onde ficam

- **Supabase URL + chave anon/publishable**: embutidas no `index.html`
  (são públicas por design, só permitem o que as regras do banco liberam).
- **Client ID do app Mercado Livre**: também no `index.html` (não é
  secreto).
- **Client Secret do Mercado Livre**: guardado em Supabase → Edge Functions
  → Secrets (`ML_CLIENT_SECRET`), nunca no front-end.
- **Chave da Claude API (Anthropic)**: guardada em Supabase → Edge
  Functions → Secrets (`ANTHROPIC_API_KEY`), mesmo padrão do
  `ML_CLIENT_SECRET` — nunca no front-end, nunca colada no chat com o
  Claude. Usada só pela Edge Function `ml-analise-ia`.
- **Permissões do app Mercado Livre habilitadas**: Métricas do negócio
  (leitura), Venda e envios de um produto (leitura e escrita), Orders_v2 +
  Stock-Locations + Shipments + Fbm Stock Operations (tópicos/webhooks).
  Publicação e sincronização também precisou ser habilitada (mesmo só pra
  leitura) pra sincronização de Full funcionar (consulta de `/items`
  também exige esse escopo). **Pendente de habilitar**: "Promoções, cupons
  e descontos" (necessária pra `ml-sync-promocoes` — ver Pendências).
  **Importante**: sempre que uma permissão nova for habilitada aqui, as 3
  contas precisam ser reconectadas na aba Integrações pra token novo pegar
  o escopo novo (ver gotcha acima). O token atual das 3 contas **já
  consegue ler pagamentos do Mercado Pago** (`/v1/payments/{id}`), usado
  pelo valor líquido — confirmado em 2026-10-05.

## Módulos construídos (status)

- ✅ Dashboard (faturamento, estoque baixo, vendas por canal) — faturamento
  via RPC `dashboard_faturamento` (sem risco de teto de linhas), SQL
  rodado e confirmado pelo dono
- ✅ Produtos (CRUD completo, com edição; peso com 5 casas; SKUs
  alternativos; busca na lista — 2026-10-05)
- ✅ Ficha Técnica (BOM)
- ✅ Estoque (saldo, movimentação manual, transferência entre locais,
  exclusão; busca no saldo — 2026-10-05)
- ✅ Compras / Ordem de Compra (no ar desde 2026-09-28)
- ✅ Produção (ordens, conclusão com baixa automática)
- ✅ Vendas (manual + importação automática via webhook ML; filtros por
  produto e texto; revínculo de itens sem produto; coluna e total de
  valor líquido do ML — 2026-10-05)
- ✅ Integrações ML (OAuth das 3 contas com renovação automática de token,
  sincronização de estoque Full automática via pg_cron diário + botão
  manual, sincronização de métricas de campanhas de Mercado Ads também
  automática via pg_cron diário + botão manual, sincronização de perguntas
  em aberto automática via pg_cron diário + botão manual; backfill do
  valor líquido — 2026-10-05)
- ✅ Gestão de Contas (aba criada em 2026-09-06): card recolhível de
  Perguntas em aberto das 3 contas, com resposta direto pelo ERP enviada
  pro Mercado Livre e feedback de sucesso/erro na hora — confirmado
  funcionando de ponta a ponta pelo dono
- 🟡 Gestão de Contas — Promoções ativas e vencendo (front-end pronto e no
  ar desde 2026-09-06; falta deployar a tabela + Edge Function +
  agendamento no Supabase, e habilitar/reconectar a permissão nova no
  Mercado Livre — ver Pendências)
- 🟡 Gestão de Contas — Métricas de Anúncios + Gestor de Contas (IA)
  (front-end pronto e no ar desde 2026-09-06; falta deployar as 2 tabelas
  + 2 Edge Functions + 3 agendamentos no Supabase, e criar/configurar a
  chave da Claude API — ver Pendências). Bug do bloco "Anúncios" sempre
  vazio (qualquer período) corrigido no código-fonte em `ml-analise-ia.ts`
  — só será testável depois do deploy inicial da função.
- ✅ Segurança básica: RLS + proteção de exclusão de produto por digitação
  de SKU
- ✅ Textos configuráveis: bloco único "PERSONALIZAÇÃO" no topo do
  `index.html` com nomes de conta, menu, e ~75 rótulos/títulos/botões

## Ainda não construído / Fase 2

- ✅ Contas a receber (2026-10-06) — ❌ contas a pagar (estrutura pronta: `natureza = 'pagar'`)
- ❌ Fluxo de caixa
- ❌ Integração fiscal com o Tiny (emissão de NF-e a partir do pedido)
- ❌ Login/permissões por usuário (hoje é acesso livre pra quem tem o link)
- ❌ Cadastro de clientes de verdade (tabela `clientes` existe mas não é
  usada — pedido guarda só nome em texto solto)
- 🟡 Revisão de itens de pedido sem produto — desde 2026-10-05 existe o
  botão "Revincular itens sem produto" + campo de SKUs alternativos; ainda
  não há uma tela dedicada listando só os itens pendentes.
- 🟡 Valor líquido no Dashboard — hoje aparece na aba Vendas e em Contas a receber.
- 🟡 Chat interativo com o Gestor de Contas (IA) — cogitado, decidido
  explicitamente que NÃO entra nesta versão (só o relatório automático
  por enquanto); pode ser um passo futuro

## Pendências específicas em aberto no momento

- **Nova (2026-10-06): 2 chargebacks** (contestação no cartão — conta 2,
  pedido 2000018543800388, R$ 19,90; conta 3, pedido 2000018302890224,
  R$ 23,34): o pagamento foi estornado mas o pedido no ML segue "pago" →
  ficam no faturamento e saem do contas a receber. Decidir se chargeback
  deve sair do faturamento.
- **Nova (2026-10-06): produção em etapas** — cadastrar Chapa para caixa 29x14x16, Chapa Cortada 19x12x12 e 29x14x16, custo das chapas e as fichas (equipe). Só ligar Caixa D3/D7 às cortadas depois que as chapas tiverem custo (ver Lote 6).
- **Nova (2026-10-06): custos** — ~70% das vendas ainda sem custo (19 dos 44
  produtos acabados ativos sem custo; 128 itens de pedido sem produto). O
  lucro só fica completo depois de cadastrar custo/ficha técnica.

- ✅ (2026-10-05) Valor líquido das vendas novas conferido pelo dono contra
  o "Você recebe" do painel do ML — batendo.
- ✅ (2026-10-06) Backfill do líquido e do contas a receber rodado nas
  2.323 vendas ML; os cancelados no ML saíram do faturamento (ver Lote 4).
- **Nova (2026-10-05): mapear os 285 itens com SKU antigo** — no produto
  certo, preencher "SKUs antigos/alternativos" e clicar em "Revincular
  itens sem produto" (aba Vendas). Sugestões do Claude, a confirmar pelo
  dono: KIT4ROLOETIQUETA200 e 4ROLOETIQUETA200 → KIT4ROLO200;
  ROLOETIQUETA200 → ROLO200; ROLOETIQUET127 → ROLO127; KIT4ETIQUETA127 e
  KIT4ROLOETIQUETATÉRMICA127 → KIT4ROLO127; KIT6ROLOETIQUETATERMICA127 →
  KIT6ROLO127; ADESIVOACNE, KIT50CAIXAS191212, KIT25CAIXAS19X14X16 → dono
  precisa indicar.
- Sincronização de estoque Full confirmada funcionando automaticamente via
  pg_cron (testada em 2026-09-05, `status_code: 200`).
- Sincronização de métricas de Mercado Ads confirmada funcionando
  automaticamente via pg_cron (testada em 2026-09-06, números batendo com
  o Mercado Ads nas 3 contas).
- Sincronização de perguntas em aberto confirmada funcionando via botão
  manual e via pg_cron diário (05:20 Brasília) — testada em 2026-09-06.
- Aba "Gestão de Contas" criada em 2026-09-06 com o card de Perguntas em
  aberto (listar + responder pelo ERP + feedback de sucesso/erro),
  **módulo confirmado funcionando de ponta a ponta pelo dono em
  2026-09-06** (Edge Function `ml-responder-pergunta` deployada e
  respondendo perguntas de verdade no Mercado Livre). Card transformado em
  card recolhível (accordion) no mesmo dia, como padrão reutilizável pra
  futuros cards da aba.
- **Gotcha resolvido (2026-09-06): `Unauthorized` ao responder pergunta**
  — o app do Mercado Livre estava só com permissão de Leitura quando as
  3 contas foram conectadas via OAuth; o dono mudou a permissão do app
  pra Leitura e Escrita, mas os tokens já emitidos continuaram só com
  Leitura (escopo OAuth fica fixo no token no momento da emissão —
  renovar via `refresh_token` reusa o mesmo escopo antigo, não pega
  escopo novo). Resolvido reconectando (botão "Reconectar") as 3 contas
  na aba Integrações, gerando tokens novos já com Leitura e Escrita.
  **Lição pra futuro**: sempre que uma permissão nova for habilitada no
  app do Mercado Livre Devs Center, as contas já conectadas precisam ser
  reconectadas (reautorizadas) — mudar a permissão do app sozinho não
  atualiza os tokens existentes.
- **Em andamento (2026-09-06): sincronização de Promoções ativas e
  vencendo.** Front-end (card recolhível "Promoções ativas e vencendo" em
  Gestão de Contas + botão "Sincronizar Promoções agora" na aba
  Integrações) já commitado no GitHub e confirmado funcionando ao vivo
  (verificado por SHA-256 + captura de tela + console sem erros). Falta,
  do lado do dono, pra fechar o ciclo:
  1. Rodar `016_promocoes_ativas.sql` no SQL Editor do Supabase (cria a
     tabela `ml_promocoes_ativas`).
  2. Criar a Edge Function `ml-sync-promocoes` no Supabase colando o
     código de `ml-sync-promocoes.ts` (**lembrar de desligar "Verify
     JWT"**, igual as outras).
  3. No Mercado Livre Devs Center, habilitar a permissão funcional
     "Promoções, cupons e descontos" (leitura já basta) no app, e depois
     **reconectar as 3 contas** na aba Integrações do ERP (gotcha do
     escopo OAuth se aplica de novo aqui).
  4. Rodar `017_cron_sync_promocoes.sql` no SQL Editor do Supabase (cria o
     agendamento diário às 05:30 Brasília, dez minutos depois do de
     Perguntas).
  Depois disso, testar o botão "Sincronizar Promoções agora" e conferir o
  card na aba Gestão de Contas.
- **Em andamento (2026-09-06): Métricas de Anúncios + Gestor de Contas
  (IA).** Front-end (card "Gestor de Contas (IA)" em Gestão de Contas +
  botão "Sincronizar Métricas de Anúncios agora" na aba Integrações) já
  commitado no GitHub e confirmado funcionando ao vivo (verificado por
  SHA-256 + captura de tela). Falta, do lado do dono, pra fechar o ciclo:
  1. Rodar `018_anuncios_metricas.sql` no SQL Editor do Supabase (cria a
     tabela `ml_anuncios_metricas` e corrige `produto_id` de
     `ml_perguntas_abertas`/`ml_promocoes_ativas` pra `on delete set
     null`).
  2. Criar a Edge Function `ml-sync-anuncios-metricas` colando o código
     de `ml-sync-anuncios-metricas.ts` (**lembrar de desligar "Verify
     JWT"**).
  3. Rodar `019_cron_sync_anuncios_metricas.sql` (agendamento diário às
     05:40 Brasília).
  4. Rodar `020_analises_ia.sql` (cria a tabela `ml_analises`).
  5. Criar a Edge Function `ml-analise-ia` colando o código **já
     corrigido** de `ml-analise-ia.ts` (**Verify JWT desligado**) e,
     **antes de testar**, criar uma chave em `platform.claude.com` →
     Settings → API Keys e colar como segredo `ANTHROPIC_API_KEY` em
     Supabase → Edge Functions → Secrets dessa função (nunca no chat,
     nunca no repositório).
  6. Rodar `021_cron_analises_ia.sql` (3 agendamentos: diária 05:50,
     semanal segunda 06:00, mensal dia 1 06:10, todos Brasília).
  Depois disso, testar o botão "Gerar agora" no card e conferir se a
  análise aparece (inclusive a seção "Anúncios", já corrigida).
- Produtos da linha "Little Tree" já estão marcados como `ativo = false`
  no cadastro — qualquer análise nova deve filtrar por `ativo = true`
  pra excluí-los automaticamente.
