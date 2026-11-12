-- ============================================================
-- Lote 12 — Conteúdo do site editável pelo ERP (aba "Site")
-- 2026-11-12
--  * site_banners: as fotos de banner que você sobe; só UMA fica ativa por vez
--    (é a que aparece no topo da página inicial). Cada banner tem seus textos.
--  * site_categorias: foto e frase dos cartões Caixas / Etiquetas / Sacos / Fitas.
--  * produtos.ordem_vitrine: ordem dos produtos marcados como Destaque na
--    vitrine da página inicial (o campo "destaque" já existia).
--  * site_conteudo(): função pública que o site chama (banner ativo,
--    categorias e a lista ordenada de ids da vitrine).
--  * Preenche a categoria dos 18 produtos visíveis na loja (estava vazia).
-- As imagens usam o mesmo armazenamento das fotos de produto
-- (bucket público "produtos-fotos", pasta "site/").
-- ============================================================

create table if not exists public.site_banners (
  id                 uuid primary key default gen_random_uuid(),
  nome               text not null,
  imagem_url         text not null,
  imagem_mobile_url  text,
  titulo             text,
  frase              text,
  botao_texto        text,
  botao_link         text,
  ativo              boolean not null default false,
  created_at         timestamptz not null default now()
);
-- no máximo um banner ativo
create unique index if not exists site_banners_um_ativo on public.site_banners ((true)) where ativo;

alter table public.site_banners enable row level security;
drop policy if exists acesso_site_banners on public.site_banners;
create policy acesso_site_banners on public.site_banners for all to authenticated using (true) with check (true);

create table if not exists public.site_categorias (
  slug        text primary key check (slug in ('caixas', 'etiquetas', 'sacos', 'fitas')),
  nome        text not null,
  frase       text,
  imagem_url  text,
  ordem       integer not null default 0,
  updated_at  timestamptz not null default now()
);
alter table public.site_categorias enable row level security;
drop policy if exists acesso_site_categorias on public.site_categorias;
create policy acesso_site_categorias on public.site_categorias for all to authenticated using (true) with check (true);

insert into public.site_categorias (slug, nome, frase, ordem) values
  ('caixas',    'Caixas de papelão',  'Seis medidas, da 12,3×12,3×8 à 29×14×16 cm', 1),
  ('etiquetas', 'Etiquetas térmicas', '10×15 cm, rolos de 127 ou 200 folhas e resma de 10 mil', 2),
  ('sacos',     'Sacos de envio',     'Com lacre, sete medidas de 19×25 a 50×70 cm', 3),
  ('fitas',     'Fitas adesivas',     '300 m por 45 mm, laranja ou transparente', 4)
on conflict (slug) do nothing;

alter table public.produtos add column if not exists ordem_vitrine integer;

create or replace function public.site_conteudo()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'banner', (
      select jsonb_build_object('imagem_url', b.imagem_url, 'imagem_mobile_url', b.imagem_mobile_url,
                                'titulo', b.titulo, 'frase', b.frase,
                                'botao_texto', b.botao_texto, 'botao_link', b.botao_link)
      from site_banners b where b.ativo limit 1
    ),
    'categorias', coalesce((
      select jsonb_agg(jsonb_build_object('slug', c.slug, 'nome', c.nome, 'frase', c.frase, 'imagem_url', c.imagem_url) order by c.ordem)
      from site_categorias c
    ), '[]'::jsonb),
    'vitrine', coalesce((
      select jsonb_agg(p.id order by p.ordem_vitrine nulls last, coalesce(p.titulo_loja, p.nome))
      from produtos p
      where p.destaque and p.visivel_loja and p.ativo
    ), '[]'::jsonb)
  );
$$;
grant execute on function public.site_conteudo() to anon, authenticated;

-- categoria dos produtos que já estão na loja (só preenche onde está vazia)
update public.produtos set categoria = case
    when coalesce(titulo_loja, nome) ilike 'caixa%' then 'caixas'
    when coalesce(titulo_loja, nome) ilike any (array['rolo%', 'etiqueta%', 'resma%']) then 'etiquetas'
    when coalesce(titulo_loja, nome) ilike 'saco%' then 'sacos'
    when coalesce(titulo_loja, nome) ilike 'fita%' then 'fitas'
  end
where visivel_loja and categoria is null
  and coalesce(titulo_loja, nome) ilike any (array['caixa%', 'rolo%', 'etiqueta%', 'resma%', 'saco%', 'fita%']);
