-- 1. Adiciona a coluna nova, ainda nullable e sem FK
alter table public.precos_comunidade
  add column envio_item_id bigint;

-- 2. Backfill: para cada dia já existente, aponta o item confirmado mais recente daquele dia
update public.precos_comunidade c
set envio_item_id = (
  select i.id
  from public.envio_itens i
  where i.posto_id = c.posto_id
    and i.produto_id = c.produto_id
    and i.criado_em::date = c.dia
    and i.status = 'confirmado'
  order by i.criado_em desc
  limit 1
);

-- 3. Agora sim a FK
alter table public.precos_comunidade
  add constraint precos_comunidade_envio_item_id_fkey
  foreign key (envio_item_id) references public.envio_itens (id) on delete set null;

-- 4. Remove a coluna antiga
alter table public.precos_comunidade
  drop column preco;

-- 5. View que lê o valor de envio_itens
create or replace view public.precos_comunidade_valor as
select c.posto_id, c.produto_id, c.dia, i.preco,
       c.envios, c.usuarios, c.confirmado
from public.precos_comunidade c
join public.envio_itens i on i.id = c.envio_item_id;