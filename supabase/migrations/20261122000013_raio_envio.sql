-- Posição exata: 300 -> 100 m
update public.parametros set valor = 100,
  descricao = 'Distância máxima entre o usuário e o posto para enviar preço (posição exata)'
 where chave = 'raio_envio_m';

-- Posição aproximada: 1000 -> 100 m (mesma faixa, mas ainda maior que o exato não faz sentido;
-- se quiser manter a hierarquia, use 200 m aqui e 100 m no exato)
update public.parametros set valor = 100,
  descricao = 'Distância máxima para enviar preço quando a posição do posto é aproximada'
 where chave = 'raio_envio_aproximado_m';