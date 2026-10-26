# Integração a aplicar no Lovable

Esta entrega contém um backend NOVO, não uma cópia das rotas já publicadas. A documentação antiga implementava rotas no próprio aplicativo. A nova implementação usa uma Supabase Edge Function isolada para permitir uma entrega completa sem presumir arquivos/schema não fornecidos. Não redirecionar os agentes antigos para ela antes da migração.

## Pedido pronto para o Lovable

> Integre a pasta `lovable/` do Infra Monitor UFFA 2.0. Preserve todas as tabelas, métricas, credenciais e cadastros existentes. Revise o schema real antes de aplicar a migração nova `202610230001_infra_monitor_v2.sql`; NÃO reaplique 0011/0012 nem o SQL antigo anexo. Publique a Edge Function `infra-monitor` com verificação JWT do gateway desativada, mantendo a verificação interna de tokens individuais e JWT administrativo. Cadastre os secrets de backend indicados abaixo. Integre `InfraMonitorPanel.tsx` numa rota administrativa `/infra-monitor`, usando o cliente Supabase autenticado existente. Adicione link na navegação e na página dos hosts para vincular/migrar os atuais. O cadastro de novos agentes deve ocorrer no frontend, emitir código de uso único e nunca expor service_role ou token de host. Ajuste as telas/alertas/cron antigos para, nos hosts com vínculo em `im_hosts.legacy_host_id`, usar o heartbeat e os timestamps v2 e não gerar falso offline pelo fluxo antigo. Não aplique novas regras de auto-restart por inferência de falta de comunicação. Valide os fluxos com um host de homologação antes de migrar as lojas.

## Arquivos

- Copiar `supabase/functions/infra-monitor/{index.ts,validation.ts}`.
- Incorporar o bloco `[functions.infra-monitor] verify_jwt=false` no `supabase/config.toml` existente, preservando os outros blocos.
- Adicionar a migração nova ao histórico real com numeração compatível. Não alterar o conteúdo de migrations já aplicadas. A migração cria apenas tabelas/funções `im_*`, índices, políticas e grants específicos.
- Copiar `frontend/InfraMonitorPanel.tsx` para os componentes do aplicativo. A rota administrativa deve renderizar:

```tsx
<InfraMonitorPanel
  supabase={supabase}
  apiBaseUrl="https://SEU-PROJETO.supabase.co/functions/v1/infra-monitor"
/>
```

A importação de `supabase` e o registro da rota devem seguir o projeto real, cujo código não foi fornecido. Não existe URL de projeto real preenchida na entrega. O frontend não usa service_role. A autorização efetiva é validada no backend, mesmo que alguém tente abrir a rota sem a proteção visual.

## Schema que precisa ser confirmado

A imagem e os anexos mostram `hosts`, `user_roles`, `host_tokens`, `metrics`, entre outras. A migração depende somente de `public.hosts(id UUID)`, `public.user_roles(user_id UUID,role TEXT)` e `auth.users(id UUID)`. Validar esses campos no banco real. Não interpreta nem modifica a estrutura desconhecida de `host_tokens`/`agent_keys`.

`im_hosts` mantém a identidade v2 e um vínculo opcional `legacy_host_id` com `hosts.id`. Na importação, o ID v2 é o mesmo UUID antigo, e o hash importado permite reutilizar o token no agente. Novas lojas são cadastradas em `im_hosts` pelo novo painel. O painel antigo não ganha automaticamente esses novos registros; integrar a navegação/listagem com a fonte v2 ou usar a rota nova como painel dessas lojas. O histórico antigo continua consultável na tela antiga.

## Configuração no backend

Supabase já fornece `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` no runtime de Edge Functions. Nunca colocar esses valores no frontend ou no agente.

Definir com segurança no projeto:

- `IM_ENROLLMENT_SECRET`: segredo aleatório de pelo menos 32 caracteres, idealmente 32 bytes em hex. Não trocar durante uma janela de cadastro pendente. Serve para derivar de forma determinística o token retornado em retries do mesmo cadastro.
- `ALLOWED_ORIGINS`: origens HTTPS exatas do painel, separadas por vírgula; incluir produção e homologação necessárias. Exemplo não secreto: `https://infro-monitor.lovable.app`. Sem wildcard. Agentes não enviam Origin.

Deploy pelo fluxo de publicação de Edge Functions do projeto. Não fornecer valores em chat. O frontend usa o JWT da sessão e papel `admin` em `user_roles`, já existente no anexo. Não concede admin automaticamente por e-mail.

## Regras importantes

- Todas as escritas passam pelo backend. A sessão do navegador não pode ler hashes de token/cadastro nem escrever direto nas tabelas.
- Cadastro retorna código de 256 bits por 30 minutos. O código só aparece na resposta; o banco guarda hash. O token de host só é retornado ao instalador autorizado pelo código.
- Troca de token de host ativo não é uma função da atualização. Reemissão de código só aceita cadastro sem identidade ativa; recuperação deliberada exige procedimento administrativo separado.
- `agent-pull-config` devolve configurações e os mesmos comandos dispatched ainda válidos. Sem reentrega, uma resposta perdida descartaria a operação.
- Identidade do host vem exclusivamente dos headers. IDs de comando precisam pertencer a esse host. Caminhos/scripts enviados pela rede não são aceitos como instrução de execução.
- Sem comunicação não significa serviço parado. O frontend usa `last_seen_at` do servidor; processos têm observação independente e saúde `unknown`/`healthy`/`unhealthy`/`down`.
- Não usar a automação antiga de 2 minutos para hosts v2. Excluir explicitamente hosts vinculados do cron `teams-notify` e dos alertas antigos de agente/processo, ou adaptar esse código para consumir o estado v2. Esse código não foi fornecido e sua alteração não é feita automaticamente por esta pasta.
- Novos eventos/avisos Teams e auto-restart não são implementados nesta versão. As ações remotas são administrativas, explícitas e auditadas. Não anunciar esse fluxo como pronto até integrar e testar o canal existente.

## Retenção e operação

As observações são append-only e deduplicadas por ID. Definir retenção de 90 dias no cron administrativo do projeto, após aprovação da política. Exemplo de operação programável, não executada pela entrega:

```sql
DELETE FROM public.im_observations WHERE received_at < now() - interval '90 days';
```

Não apagar auditoria ou diário local de comandos na mesma rotina. A expiração de comandos é processada em pull/novo enfileiramento; enquanto o host estiver offline, a UI pode mostrar um comando antigo até o próximo processamento. Configurar rate limiting no gateway para os endpoints públicos; tokens/códigos têm 256 bits, mas não substituem limitação de abuso.

## Homologação do Lovable

Validar sessão admin e recusa de usuário comum; cadastro novo; importação de UUID/hash antigo; código expirado/reutilizado; IP por host; alterações de intervalo; heartbeat com relógio do servidor; dados antigos destacados; comando com motivo; reentrega; resultado idêntico repetido; recusa de outro host; fila única; auditoria. Conferir logs sem segredos. Publicação da interface não comprova integração Windows nem entrega de Teams.
