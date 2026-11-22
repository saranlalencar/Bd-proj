-- gasprice · regras de negócio no servidor
-- Os números usados aqui estão documentados em documentacao/regras_de_negocio.html.

-- ---------------------------------------------------------------------------
-- Parâmetros das regras (um lugar só para ajustar)
-- ---------------------------------------------------------------------------
create table public.parametros (
  chave  text primary key,
  valor  numeric not null,
  descricao text not null
);
alter table public.parametros enable row level security;
create policy "leitura publica" on public.parametros for select to anon, authenticated using (true);

insert into public.parametros (chave, valor, descricao) values
  ('raio_envio_m',            300,  'Distância máxima entre o usuário e o posto para enviar preço'),
  ('tolerancia_consenso',     0.02, 'Diferença máxima em R$ para dois envios contarem como o mesmo preço'),
  ('janela_consenso_h',       24,   'Janela de tempo em horas para formar consenso'),
  ('usuarios_consenso',       2,    'Usuários distintos necessários para confirmar um preço'),
  ('usuarios_consenso_revisao', 3,  'Usuários distintos necessários quando o envio está em revisão'),
  ('desvio_revisao',          0.20, 'Desvio relativo ao preço de referência que coloca o envio em revisão'),
  ('validade_confirmado_d',   7,    'Dias em que um preço confirmado continua sendo exibido'),
  ('intervalo_mesmo_item_h',  6,    'Intervalo mínimo em horas entre envios do mesmo usuário, posto e combustível'),
  ('envios_por_dia',          20,   'Envios por usuário por dia'),
  ('pontos_confirmado',       10,   'Pontos por envio confirmado'),
  ('pontos_primeiro',         5,    'Bônus para o primeiro envio em posto sem atualização há mais de 24 h'),
  ('pontos_contestado',       -5,   'Pontos quando o envio é contrariado pelo consenso'),
  ('multiplicador_sem_anp',   2,    'Multiplicador de pontos em município sem coleta da ANP'),
  ('teto_pontos_dia',         200,  'Máximo de pontos ganhos por dia'),
  ('confiabilidade_min',      0.20, 'Abaixo disso o envio sempre entra em revisão'),
  ('variacao_notificacao',    0.05, 'Variação mínima em R$ para notificar quem favoritou o posto');

create or replace function public.parametro(p_chave text)
returns numeric
language sql
stable
set search_path = ''
as $$ select valor from public.parametros where chave = p_chave $$;

-- ---------------------------------------------------------------------------
-- Perfil criado automaticamente no cadastro
-- ---------------------------------------------------------------------------
create or replace function public.criar_perfil()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nome text := coalesce(nullif(trim(new.raw_user_meta_data ->> 'nome'), ''), split_part(coalesce(new.email, ''), '@', 1));
begin
  if char_length(v_nome) < 2 then
    v_nome := 'Usuário';
  end if;
  insert into public.perfis (id, nome) values (new.id, left(v_nome, 60));
  return new;
end;
$$;

create trigger ao_criar_usuario
  after insert on auth.users
  for each row execute function public.criar_perfil();

-- ---------------------------------------------------------------------------
-- Nota média do posto e votos das avaliações (calculados no servidor)
-- ---------------------------------------------------------------------------
create or replace function public.recalcular_nota_posto()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_posto bigint := coalesce(new.posto_id, old.posto_id);
begin
  update public.postos p set
    nota_media = s.media,
    total_avaliacoes = s.total
  from (
    select round(avg(nota)::numeric, 2) as media, count(*)::int as total
    from public.avaliacoes where posto_id = v_posto
  ) s
  where p.id = v_posto;
  return null;
end;
$$;

create trigger ao_mudar_avaliacao
  after insert or update of nota or delete on public.avaliacoes
  for each row execute function public.recalcular_nota_posto();

create or replace function public.marcar_avaliacao_editada()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;

create trigger ao_editar_avaliacao
  before update on public.avaliacoes
  for each row execute function public.marcar_avaliacao_editada();

create or replace function public.recalcular_votos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint := coalesce(new.avaliacao_id, old.avaliacao_id);
begin
  update public.avaliacoes set votos_uteis = (select count(*) from public.avaliacao_votos where avaliacao_id = v_id)
  where id = v_id;
  return null;
end;
$$;

create trigger ao_votar
  after insert or delete on public.avaliacao_votos
  for each row execute function public.recalcular_votos();

-- ---------------------------------------------------------------------------
-- Pontos (com teto diário) e confiabilidade
-- ---------------------------------------------------------------------------
create or replace function public.registrar_pontos(
  p_usuario uuid, p_item bigint, p_tipo text, p_pontos integer, p_descricao text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ganhos_hoje integer;
  v_teto integer := public.parametro('teto_pontos_dia');
  v_pontos integer := p_pontos;
begin
  if p_usuario is null or p_pontos = 0 then
    return 0;
  end if;
  if p_pontos > 0 then
    select coalesce(sum(pontos), 0) into v_ganhos_hoje
    from public.pontos_movimentos
    where usuario_id = p_usuario and pontos > 0 and criado_em >= date_trunc('day', now());
    v_pontos := least(p_pontos, greatest(v_teto - v_ganhos_hoje, 0));
    if v_pontos = 0 then
      return 0;
    end if;
  end if;
  insert into public.pontos_movimentos (usuario_id, envio_item_id, tipo, pontos, descricao)
  values (p_usuario, p_item, p_tipo, v_pontos, p_descricao);
  update public.perfis set pontos = greatest(pontos + v_pontos, 0) where id = p_usuario;
  return v_pontos;
end;
$$;

create or replace function public.ajustar_confiabilidade(p_usuario uuid, p_delta numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contestados integer;
begin
  update public.perfis
  set confiabilidade = least(1, greatest(0, confiabilidade + p_delta))
  where id = p_usuario;

  -- 3 envios contestados em 7 dias bloqueiam novos envios por 7 dias
  if p_delta < 0 then
    select count(*) into v_contestados
    from public.envio_itens
    where usuario_id = p_usuario and status = 'contestado' and criado_em >= now() - interval '7 days';
    if v_contestados >= 3 then
      update public.perfis set bloqueado_ate = now() + interval '7 days' where id = p_usuario;
    end if;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Preço exibido no app para um posto e combustível
-- Ordem: comunidade confirmada (7 dias) > comunidade recente sem divergência (24 h)
--        > ANP quando há divergência > o mais recente entre comunidade não
--        confirmada e ANP > estimativa regional.
-- ---------------------------------------------------------------------------
create or replace function public.calcular_preco_exibido(p_posto bigint, p_produto smallint)
returns table (
  preco numeric, fonte public.fonte_preco, situacao public.situacao_preco,
  atualizado_em timestamptz, confirmacoes integer, margem numeric, distancia_km numeric)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tol numeric := public.parametro('tolerancia_consenso');
  v_conf record;
  v_pend record;
  v_anp record;
  v_nc record;
  v_est record;
begin
  -- 1. Comunidade confirmada nos últimos 7 dias
  select i.preco, c.usuarios, c.dia,
         (select max(x.consolidado_em) from public.envio_itens x
           where x.posto_id = p_posto and x.produto_id = p_produto and x.status = 'confirmado'
             and x.criado_em::date = c.dia) as quando
    into v_conf
  from public.precos_comunidade c
  join public.envio_itens i on i.id = c.envio_item_id
  where c.posto_id = p_posto and c.produto_id = p_produto and c.confirmado
    and c.dia >= current_date - public.parametro('validade_confirmado_d')::int
  order by c.dia desc
  limit 1;

  -- Envios pendentes nas últimas 24 h. Envios em revisão (suspeitos) não aparecem
  -- como preço exibido: só contam para formar consenso.
  select count(distinct i.usuario_id) as usuarios,
         min(i.preco) as minimo, max(i.preco) as maximo,
         (array_agg(i.preco order by i.criado_em desc))[1] as ultimo,
         percentile_cont(0.5) within group (order by i.preco) as mediana,
         max(i.criado_em) as quando
    into v_pend
  from public.envio_itens i
  where i.posto_id = p_posto and i.produto_id = p_produto and i.status = 'pendente'
    and not i.em_revisao
    and i.criado_em >= now() - make_interval(hours => public.parametro('janela_consenso_h')::int);

  -- Um preço confirmado só é substituído por um novo consenso, nunca por um envio isolado
  if v_conf.preco is not null then
    return query select v_conf.preco, 'comunidade'::public.fonte_preco, 'confirmado'::public.situacao_preco,
                        coalesce(v_conf.quando, v_conf.dia::timestamptz), v_conf.usuarios, null::numeric, null::numeric;
    return;
  end if;

  select a.preco, a.data_coleta into v_anp
  from public.precos_anp a
  where a.posto_id = p_posto and a.produto_id = p_produto and not a.anomalia
  order by a.data_coleta desc
  limit 1;

  -- 2. Envios recentes: sem divergência mostra o último; com divergência vale a ANP
  if v_pend.quando is not null then
    if v_pend.maximo - v_pend.minimo <= v_tol then
      return query select v_pend.ultimo, 'comunidade'::public.fonte_preco, 'nao_confirmado'::public.situacao_preco,
                          v_pend.quando, v_pend.usuarios::int, null::numeric, null::numeric;
      return;
    elsif v_anp.preco is not null then
      return query select v_anp.preco, 'anp'::public.fonte_preco, 'divergente'::public.situacao_preco,
                          v_anp.data_coleta::timestamptz, 0, null::numeric, null::numeric;
      return;
    else
      return query select round(v_pend.mediana::numeric, 3), 'comunidade'::public.fonte_preco, 'divergente'::public.situacao_preco,
                          v_pend.quando, v_pend.usuarios::int, null::numeric, null::numeric;
      return;
    end if;
  end if;

  -- 3. Comunidade não confirmada (mais de 24 h) contra ANP: vale a mais recente; empate fica com a ANP
  select i.preco, c.dia, c.usuarios into v_nc
  from public.precos_comunidade c
  join public.envio_itens i on i.id = c.envio_item_id
  where c.posto_id = p_posto and c.produto_id = p_produto and not c.confirmado
    and c.dia >= current_date - public.parametro('validade_confirmado_d')::int
  order by c.dia desc
  limit 1;

  if v_nc.preco is not null and (v_anp.preco is null or v_nc.dia > v_anp.data_coleta) then
    return query select v_nc.preco, 'comunidade'::public.fonte_preco, 'nao_confirmado'::public.situacao_preco,
                        v_nc.dia::timestamptz, v_nc.usuarios, null::numeric, null::numeric;
    return;
  end if;

  -- 4. ANP
  if v_anp.preco is not null then
    return query select v_anp.preco, 'anp'::public.fonte_preco, 'oficial'::public.situacao_preco,
                        v_anp.data_coleta::timestamptz, 0, null::numeric, null::numeric;
    return;
  end if;

  -- 5. Estimativa regional
  select e.preco, e.margem, e.distancia_km, e.calculado_em into v_est
  from public.precos_estimados e
  where e.posto_id = p_posto and e.produto_id = p_produto;

  if v_est.preco is not null then
    return query select v_est.preco, 'estimativa'::public.fonte_preco, 'estimado'::public.situacao_preco,
                        v_est.calculado_em, 0, v_est.margem, v_est.distancia_km;
  end if;
end;
$$;

-- Atualiza precos_atuais e notifica quem favoritou, se o preço mudou o bastante
create or replace function public.atualizar_preco_atual(p_posto bigint, p_produto smallint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_antigo public.precos_atuais%rowtype;
  v_novo record;
  v_confiavel_antes numeric;
  v_confiavel_depois numeric;
  v_confiavel boolean;
begin
  select * into v_antigo from public.precos_atuais where posto_id = p_posto and produto_id = p_produto;
  select * into v_novo from public.calcular_preco_exibido(p_posto, p_produto);

  if v_novo.preco is null then
    delete from public.precos_atuais where posto_id = p_posto and produto_id = p_produto;
    return;
  end if;

  -- O aviso compara preços confiáveis (confirmado ou oficial), nunca um envio isolado
  v_confiavel_antes := coalesce(
    v_antigo.ultimo_confiavel,
    case when v_antigo.situacao in ('confirmado', 'oficial') then v_antigo.preco end);
  v_confiavel := v_novo.situacao in ('confirmado', 'oficial');
  v_confiavel_depois := case when v_confiavel then v_novo.preco else v_confiavel_antes end;

  insert into public.precos_atuais as a
    (posto_id, produto_id, preco, fonte, situacao, atualizado_em, confirmacoes, margem, distancia_km, ultimo_confiavel)
  values (p_posto, p_produto, v_novo.preco, v_novo.fonte, v_novo.situacao, v_novo.atualizado_em,
          v_novo.confirmacoes, v_novo.margem, v_novo.distancia_km, v_confiavel_depois)
  on conflict (posto_id, produto_id) do update set
    preco = excluded.preco, fonte = excluded.fonte, situacao = excluded.situacao,
    atualizado_em = excluded.atualizado_em, confirmacoes = excluded.confirmacoes,
    margem = excluded.margem, distancia_km = excluded.distancia_km,
    ultimo_confiavel = excluded.ultimo_confiavel;

  if v_confiavel and v_confiavel_antes is not null
     and abs(v_novo.preco - v_confiavel_antes) >= public.parametro('variacao_notificacao') then
    insert into public.notificacoes (usuario_id, posto_id, produto_id, preco_anterior, preco_novo)
    select f.usuario_id, p_posto, p_produto, v_confiavel_antes, v_novo.preco
    from public.favoritos f
    join public.perfis u on u.id = f.usuario_id
    where f.posto_id = p_posto and f.notificar and u.notificacoes_ativas;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Consenso da comunidade
-- ---------------------------------------------------------------------------
create or replace function public.consolidar_preco(p_posto bigint, p_produto smallint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tol numeric := public.parametro('tolerancia_consenso');
  v_janela interval := make_interval(hours => public.parametro('janela_consenso_h')::int);
  v_min_conf numeric := public.parametro('confiabilidade_min');
  v_melhor record;
  v_necessario integer;
  v_mult integer := 1;
  v_item record;
  v_estava_parado boolean;
  v_primeiro bigint;
  v_ganho integer;
begin
  -- Cluster com mais usuários distintos concordando (dentro da tolerância)
  select i.id, i.preco, i.em_revisao,
         (select count(distinct j.usuario_id)
            from public.envio_itens j
            join public.perfis u on u.id = j.usuario_id
           where j.posto_id = p_posto and j.produto_id = p_produto
             and j.status in ('pendente', 'confirmado')
             and j.criado_em >= now() - v_janela
             and abs(j.preco - i.preco) <= v_tol
             and u.confiabilidade >= v_min_conf
             and not u.banido) as usuarios,
         (select bool_or(j.em_revisao)
            from public.envio_itens j
           where j.posto_id = p_posto and j.produto_id = p_produto
             and j.status = 'pendente' and j.criado_em >= now() - v_janela
             and abs(j.preco - i.preco) <= v_tol) as algum_em_revisao
    into v_melhor
  from public.envio_itens i
  where i.posto_id = p_posto and i.produto_id = p_produto
    and i.status = 'pendente' and i.criado_em >= now() - v_janela
  order by 4 desc, i.criado_em desc
  limit 1;

  if v_melhor.id is null then
    perform public.atualizar_preco_atual(p_posto, p_produto);
    return;
  end if;

  v_necessario := case when v_melhor.algum_em_revisao
                       then public.parametro('usuarios_consenso_revisao')::int
                       else public.parametro('usuarios_consenso')::int end;

  if v_melhor.usuarios < v_necessario then
    perform public.atualizar_preco_atual(p_posto, p_produto);
    return;
  end if;

  select case when p.municipio_pesquisado_anp then 1 else public.parametro('multiplicador_sem_anp')::int end
    into v_mult from public.postos p where p.id = p_posto;

  -- O posto estava sem atualização da comunidade há mais de 24 h antes deste cluster?
  select not exists (
    select 1 from public.envio_itens j
    where j.posto_id = p_posto and j.produto_id = p_produto and j.status = 'confirmado'
      and j.consolidado_em >= now() - interval '24 hours'
  ) into v_estava_parado;

  select j.id into v_primeiro
  from public.envio_itens j
  where j.posto_id = p_posto and j.produto_id = p_produto and j.status = 'pendente'
    and j.criado_em >= now() - v_janela and abs(j.preco - v_melhor.preco) <= v_tol
  order by j.criado_em
  limit 1;

  -- Confirma os envios do cluster e dá os pontos
  for v_item in
    update public.envio_itens j
       set status = 'confirmado', consolidado_em = now()
     where j.posto_id = p_posto and j.produto_id = p_produto and j.status = 'pendente'
       and j.criado_em >= now() - v_janela and abs(j.preco - v_melhor.preco) <= v_tol
    returning j.id, j.usuario_id
  loop
    v_ganho := public.registrar_pontos(v_item.usuario_id, v_item.id, 'confirmado',
                 public.parametro('pontos_confirmado')::int * v_mult, 'Preço confirmado pela comunidade');
    if v_estava_parado and v_item.id = v_primeiro then
      perform public.registrar_pontos(v_item.usuario_id, v_item.id, 'primeiro',
                 public.parametro('pontos_primeiro')::int * v_mult, 'Primeiro envio em posto sem atualização');
    end if;
    perform public.ajustar_confiabilidade(v_item.usuario_id, 0.05);
  end loop;

  -- Envios pendentes da janela que discordam do consenso são contestados
  for v_item in
    update public.envio_itens j
       set status = 'contestado', consolidado_em = now()
     where j.posto_id = p_posto and j.produto_id = p_produto and j.status = 'pendente'
       and j.criado_em >= now() - v_janela and abs(j.preco - v_melhor.preco) > v_tol
    returning j.id, j.usuario_id
  loop
    perform public.registrar_pontos(v_item.usuario_id, v_item.id, 'contestado',
               public.parametro('pontos_contestado')::int, 'Preço contrariado por outros usuários');
    perform public.ajustar_confiabilidade(v_item.usuario_id, -0.10);
  end loop;

  -- Histórico diário da comunidade
  insert into public.precos_comunidade (posto_id, produto_id, dia, envios, usuarios, confirmado, envio_item_id)
  select p_posto, p_produto, current_date,
        count(*), count(distinct usuario_id), true, v_melhor.id
  from public.envio_itens
  where posto_id = p_posto and produto_id = p_produto and status = 'confirmado'
    and consolidado_em >= date_trunc('day', now())
  on conflict (posto_id, produto_id, dia) do update set
    envios = excluded.envios, usuarios = excluded.usuarios,
    confirmado = true, envio_item_id = excluded.envio_item_id;
  perform public.atualizar_preco_atual(p_posto, p_produto);
end;
$$;

-- Envios sem confirmação por mais de 24 h entram no histórico como "não confirmado"
create or replace function public.fechar_envios_antigos()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_chave record;
  v_total integer := 0;
begin
  for v_chave in
    select posto_id, produto_id, criado_em::date as dia,
           count(*) as envios, count(distinct usuario_id) as usuarios,
           (array_agg(id order by criado_em desc))[1] as envio_item_id
    from public.envio_itens
    where status = 'pendente'
      and criado_em < now() - make_interval(hours => public.parametro('janela_consenso_h')::int)
    group by 1, 2, 3
  loop
    insert into public.precos_comunidade (posto_id, produto_id, dia, envios, usuarios, confirmado, envio_item_id)
    values (v_chave.posto_id, v_chave.produto_id, v_chave.dia,
            v_chave.envios, v_chave.usuarios, false, v_chave.envio_item_id)
    on conflict (posto_id, produto_id, dia) do nothing;  -- dia já confirmado prevalece

    update public.envio_itens set status = 'expirado', consolidado_em = now()
    where posto_id = v_chave.posto_id and produto_id = v_chave.produto_id
      and status = 'pendente' and criado_em::date = v_chave.dia
      and criado_em < now() - make_interval(hours => public.parametro('janela_consenso_h')::int);

    perform public.atualizar_preco_atual(v_chave.posto_id, v_chave.produto_id);
    v_total := v_total + v_chave.envios;
  end loop;
  return v_total;
end;
$$;

-- ---------------------------------------------------------------------------
-- Estimativa regional: mediana dos 5 postos com preço ANP recente mais próximos
-- (até 200 km), com margem pela faixa de distância medida no estudo de cobertura.
-- ---------------------------------------------------------------------------
create or replace function public.recalcular_estimativas()
returns integer
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '15min'
as $$
declare
  v_total integer;
begin
  create temporary table ref on commit drop as
  select distinct on (a.posto_id, a.produto_id) a.posto_id, a.produto_id, a.preco, p.localizacao
  from public.precos_anp a
  join public.postos p on p.id = a.posto_id
  where not a.anomalia and a.data_coleta >= current_date - 60 and p.localizacao is not null
  order by a.posto_id, a.produto_id, a.data_coleta desc;
  create index on ref using gist (localizacao);
  create index on ref (produto_id);

  delete from public.precos_estimados;

  insert into public.precos_estimados (posto_id, produto_id, preco, margem, distancia_km)
  select alvo.posto_id, alvo.produto_id, round(viz.mediana::numeric, 3),
         case when viz.dist_km < 25 then 0.13 when viz.dist_km < 50 then 0.22
              when viz.dist_km < 100 then 0.24 else 0.36 end,
         round(viz.dist_km::numeric, 1)
  from (
    select pp.posto_id, pp.produto_id, p.localizacao
    from public.posto_produtos pp
    join public.postos p on p.id = pp.posto_id
    where p.ativo and p.localizacao is not null
      and not exists (select 1 from ref r where r.posto_id = pp.posto_id and r.produto_id = pp.produto_id)
  ) alvo
  cross join lateral (
    select percentile_cont(0.5) within group (order by k.preco) as mediana, min(k.dist) / 1000 as dist_km
    from (
      select r.preco, st_distance(r.localizacao, alvo.localizacao) as dist
      from ref r
      where r.produto_id = alvo.produto_id
      order by r.localizacao <-> alvo.localizacao
      limit 5
    ) k
    where k.dist <= 200000
  ) viz
  where viz.mediana is not null;

  get diagnostics v_total = row_count;
  return v_total;
end;
$$;

-- Recalcula precos_atuais de todos os postos (após importar a ANP e toda semana).
--
-- Combinações com dados da comunidade em jogo passam pelo caminho completo, uma a uma: são poucas.
-- O restante, que é a grande maioria, é calculado em bloco: a pesquisa da ANP mais recente sem
-- anomalia e, sem ela, a estimativa regional. É o mesmo resultado que calcular_preco_exibido
-- daria para essas combinações, verificado no teste de regras.
--
-- Não usar um laço posto a posto para o restante: na primeira execução, com precos_atuais vazia,
-- o plano de cada consulta é fixado com a tabela pequena e a leitura cresce a cada linha gravada,
-- o que levou mais de 10 minutos para 130 mil combinações, contra cerca de 20 segundos em bloco.
create or replace function public.recalcular_precos_atuais()
returns integer
language plpgsql
security definer
set search_path = ''
set statement_timeout = '30min'
as $$
declare
  v_chave record;
  v_total integer := 0;
  v_em_bloco integer;
  v_janela interval := make_interval(hours => public.parametro('janela_consenso_h')::int);
  v_validade integer := public.parametro('validade_confirmado_d')::int;
  v_limite numeric := public.parametro('variacao_notificacao');
begin
  -- Se a rotina rodar duas vezes na mesma transação, as tabelas temporárias da primeira ainda existem
  if to_regclass('pg_temp.combos_comunidade') is not null then drop table pg_temp.combos_comunidade; end if;
  if to_regclass('pg_temp.novos_precos') is not null then drop table pg_temp.novos_precos; end if;

  -- 1. Combinações em que a comunidade tem algo em jogo (ou que hoje exibem dado da comunidade)
  create temporary table combos_comunidade on commit drop as
    select posto_id, produto_id from public.precos_comunidade where dia >= current_date - v_validade
    union
    select posto_id, produto_id from public.envio_itens where status = 'pendente' and criado_em >= now() - v_janela
    union
    select posto_id, produto_id from public.precos_atuais where fonte = 'comunidade';
  create unique index on pg_temp.combos_comunidade (posto_id, produto_id);

  for v_chave in select posto_id, produto_id from pg_temp.combos_comunidade loop
    perform public.atualizar_preco_atual(v_chave.posto_id, v_chave.produto_id);
    v_total := v_total + 1;
  end loop;

  -- 2. O resto em bloco: ANP mais recente sem anomalia; sem ela, a estimativa
  create temporary table novos_precos on commit drop as
    select coalesce(a.posto_id, e.posto_id) as posto_id,
           coalesce(a.produto_id, e.produto_id) as produto_id,
           case when a.posto_id is not null then a.preco else e.preco end as preco,
           (case when a.posto_id is not null then 'anp' else 'estimativa' end)::public.fonte_preco as fonte,
           (case when a.posto_id is not null then 'oficial' else 'estimado' end)::public.situacao_preco as situacao,
           case when a.posto_id is not null then a.data_coleta::timestamptz else e.calculado_em end as atualizado_em,
           case when a.posto_id is null then e.margem end as margem,
           case when a.posto_id is null then e.distancia_km end as distancia_km
    from (select distinct on (posto_id, produto_id) posto_id, produto_id, preco, data_coleta
            from public.precos_anp
           where not anomalia
           order by posto_id, produto_id, data_coleta desc) a
    full join public.precos_estimados e on e.posto_id = a.posto_id and e.produto_id = a.produto_id
    where not exists (
      select 1 from pg_temp.combos_comunidade c
       where c.posto_id = coalesce(a.posto_id, e.posto_id) and c.produto_id = coalesce(a.produto_id, e.produto_id));
  create unique index on pg_temp.novos_precos (posto_id, produto_id);
  analyze pg_temp.novos_precos;
  select count(*) into v_em_bloco from pg_temp.novos_precos;

  -- Avisos para quem favoritou: preço oficial novo que muda R$ 0,05 ou mais em relação ao último preço confiável
  insert into public.notificacoes (usuario_id, posto_id, produto_id, preco_anterior, preco_novo)
  select f.usuario_id, n.posto_id, n.produto_id, x.antes, n.preco
  from pg_temp.novos_precos n
  join public.precos_atuais pa on pa.posto_id = n.posto_id and pa.produto_id = n.produto_id
  cross join lateral (
    select coalesce(pa.ultimo_confiavel, case when pa.situacao in ('confirmado', 'oficial') then pa.preco end) as antes
  ) x
  join public.favoritos f on f.posto_id = n.posto_id and f.notificar
  join public.perfis u on u.id = f.usuario_id and u.notificacoes_ativas
  where n.situacao = 'oficial' and x.antes is not null and abs(n.preco - x.antes) >= v_limite;

  -- Grava só o que mudou, para a rotina semanal não reescrever 130 mil linhas à toa
  insert into public.precos_atuais as a
    (posto_id, produto_id, preco, fonte, situacao, atualizado_em, confirmacoes, margem, distancia_km, ultimo_confiavel)
  select n.posto_id, n.produto_id, n.preco, n.fonte, n.situacao, n.atualizado_em, 0, n.margem, n.distancia_km,
         case when n.situacao = 'oficial' then n.preco
              else coalesce(pa.ultimo_confiavel, case when pa.situacao in ('confirmado', 'oficial') then pa.preco end) end
  from pg_temp.novos_precos n
  left join public.precos_atuais pa on pa.posto_id = n.posto_id and pa.produto_id = n.produto_id
  on conflict (posto_id, produto_id) do update set
    preco = excluded.preco, fonte = excluded.fonte, situacao = excluded.situacao,
    atualizado_em = excluded.atualizado_em, confirmacoes = 0, margem = excluded.margem,
    distancia_km = excluded.distancia_km, ultimo_confiavel = excluded.ultimo_confiavel
  where (a.preco, a.fonte, a.situacao, a.atualizado_em, a.margem, a.distancia_km, a.ultimo_confiavel)
        is distinct from
        (excluded.preco, excluded.fonte, excluded.situacao, excluded.atualizado_em, excluded.margem,
         excluded.distancia_km, excluded.ultimo_confiavel);

  -- Linhas que ficaram sem nenhuma fonte saem
  delete from public.precos_atuais pa
   where not exists (select 1 from pg_temp.novos_precos n where n.posto_id = pa.posto_id and n.produto_id = pa.produto_id)
     and not exists (select 1 from pg_temp.combos_comunidade c where c.posto_id = pa.posto_id and c.produto_id = pa.produto_id);

  return v_total + v_em_bloco;
end;
$$;

-- Marca os postos em municípios com coleta da ANP nos últimos 12 meses (pontos em dobro fora deles)
create or replace function public.marcar_municipios_pesquisados()
returns void
language sql
security definer
set search_path = ''
as $$
  update public.postos p set municipio_pesquisado_anp = exists (
    select 1 from public.precos_anp a join public.postos q on q.id = a.posto_id
    where q.uf = p.uf and q.municipio = p.municipio and a.data_coleta >= current_date - 365
  );
$$;

-- As funções internas não são chamáveis pelo app
revoke execute on function public.registrar_pontos(uuid, bigint, text, integer, text) from public, anon, authenticated;
revoke execute on function public.ajustar_confiabilidade(uuid, numeric) from public, anon, authenticated;
revoke execute on function public.atualizar_preco_atual(bigint, smallint) from public, anon, authenticated;
revoke execute on function public.consolidar_preco(bigint, smallint) from public, anon, authenticated;
revoke execute on function public.fechar_envios_antigos() from public, anon, authenticated;
revoke execute on function public.recalcular_estimativas() from public, anon, authenticated;
revoke execute on function public.recalcular_precos_atuais() from public, anon, authenticated;
revoke execute on function public.marcar_municipios_pesquisados() from public, anon, authenticated;
revoke execute on function public.calcular_preco_exibido(bigint, smallint) from public, anon, authenticated;
