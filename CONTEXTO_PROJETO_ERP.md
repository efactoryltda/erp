# ERP E-Factory — Resumo do Projeto

> Documento de contexto. Cole isso no "Project knowledge" de um Claude Project
> pra qualquer chat novo já nascer sabendo do estado atual do projeto.
> Atualize este arquivo de vez em quando (peça pro Claude regenerar) conforme
> o sistema evoluir.

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
  inline), hospedado no **Netlify**, conectado a um repositório **GitHub**
  (deploy automático a cada commit). Edição de textos simples pode ser feita
  direto no GitHub, sem precisar do Claude.
- **Backend**: **Supabase** (projeto `jrkuzyhobgzhjjyblmed`), Postgres +
  Edge Functions (Deno/TypeScript).
- **Fiscal**: continua no **Tiny ERP** (não integrado ainda ao novo sistema).

## Arquitetura de dados (tabelas principais)

- `produtos` — cadastro único (matéria-prima e produto acabado juntos,
  campo `tipo`). Tem `sku_interno` (único, obrigatório) e `sku_ml`
  (opcional, só quando o SKU do Mercado Livre diverge do interno).
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
  `sku_ml_item` preenchido, pra revisão manual.
- `integracoes_ml` — token de acesso de cada conta ML conectada. **Sem
  policy de acesso pra anon/authenticated de propósito** (só Edge Functions
  com service_role acessam — dados sensíveis).
- `produto_anuncios_ml` — mapeia cada produto ao ID do anúncio (`MLB...` ou
  `MLBU...`) em cada conta, usado só pra sincronização de estoque Full.

## Funções do banco (RPC)

- `concluir_ordem_producao` — baixa matéria-prima, gera produto acabado,
  calcula custo.
- `criar_pedido_venda` / `cancelar_pedido_venda` / `excluir_pedido_venda` —
  ciclo de vida do pedido, com baixa/devolução de estoque automática.
- `excluir_produto` — exclusão em cascata cuidadosa: bloqueia se o produto
  está em pedido de venda, ordem de produção, ou é matéria-prima usada na
  ficha técnica de outro produto (evita apagar relação escondida). Front-end
  exige digitar o SKU pra confirmar (proteção contra clique acidental de
  sócio).
- `transferir_estoque` — move estoque entre locais (ex: Físico → Full de
  uma conta), registrando os dois lados no histórico.
- `listar_integracoes_ml` — expõe só status de conexão (nunca os tokens).

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
  com baixa de estoque.
- `ml-sync-full-stock` — consulta o estoque Full real de cada anúncio
  cadastrado em `produto_anuncios_ml` e corrige o saldo do ERP pra bater com
  o Mercado Livre. Suporta os dois formatos de anúncio (ver nota técnica
  abaixo). **Precisa de CORS habilitado**
  (`Access-Control-Allow-Origin`) porque é chamada via `fetch()` direto do
  navegador, diferente das outras funções que o ML chama.

### Nota técnica: dois formatos de anúncio ML

- `MLBU...` (user_product_id) → `GET /user-products/{id}/stock`, campo
  `locations[].type === 'meli_facility'`.
- `MLB...` (item clássico) → dois passos: `GET /items/{id}` pra pegar
  `inventory_id`, depois `GET /inventories/{inventory_id}/stock/fulfillment`,
  campo `available_quantity`.

A função detecta automaticamente pelo prefixo do ID.

## Credenciais e onde ficam

- **Supabase URL + chave anon/publishable**: embutidas no `index.html`
  (são públicas por design, só permitem o que as regras do banco liberam).
- **Client ID do app Mercado Livre**: também no `index.html` (não é
  secreto).
- **Client Secret do Mercado Livre**: guardado em Supabase → Edge Functions
  → Secrets (`ML_CLIENT_SECRET`), nunca no front-end.
- **Permissões do app Mercado Livre habilitadas**: Métricas do negócio
  (leitura), Venda e envios de um produto (leitura e escrita), Orders_v2 +
  Stock-Locations + Shipments + Fbm Stock Operations (tópicos/webhooks).
  Publicação e sincronização também precisou ser habilitada (mesmo só pra
  leitura) pra sincronização de Full funcionar (consulta de `/items`
  também exige esse escopo).

## Módulos construídos (status)

- ✅ Dashboard (faturamento, estoque baixo, vendas por canal)
- ✅ Produtos (CRUD completo, com edição)
- ✅ Ficha Técnica (BOM)
- ✅ Estoque (saldo, movimentação manual, transferência entre locais,
  exclusão)
- ✅ Produção (ordens, conclusão com baixa automática)
- ✅ Vendas (manual + importação automática via webhook ML)
- ✅ Integrações ML (OAuth das 3 contas, sincronização de estoque Full)
- ✅ Segurança básica: RLS + proteção de exclusão de produto por digitação
  de SKU
- ✅ Textos configuráveis: bloco único "PERSONALIZAÇÃO" no topo do
  `index.html` com nomes de conta, menu, e ~75 rótulos/títulos/botões

## Ainda não construído / Fase 2

- ❌ Compras / fornecedores
- ❌ Contas a pagar / a receber
- ❌ Fluxo de caixa
- ❌ Integração fiscal com o Tiny (emissão de NF-e a partir do pedido)
- ❌ Login/permissões por usuário (hoje é acesso livre pra quem tem o link)
- ❌ Marketing/Anúncios/Promoções (decidido deixar de fora por enquanto)
- ❌ Cadastro de clientes de verdade (tabela `clientes` existe mas não é
  usada — pedido guarda só nome em texto solto)
- ❌ Sincronização automática/agendada do Full (hoje é botão manual
  "Sincronizar Full agora")
- ❌ Tela de revisão de itens de pedido sem produto identificado (hoje só
  fica marcado no banco, sem UI dedicada)

## Pendências específicas em aberto no momento

- Testando a sincronização de estoque Full pela primeira vez (permissão
  "Publicação e sincronização" acabou de ser liberada, aguardando teste
  depois de reconectar as 3 contas).
