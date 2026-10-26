# Instalação, migração e atualização

## Pré-requisitos

Windows com PowerShell 5.1 e .NET Framework 4.7.2 ou superior; executar instaladores como administrador. Testar em Windows Server 2016+ antes de distribuir. Agente usa LocalSystem para WMI, SCM e catálogo; a raiz é acessível somente a SYSTEM e Administradores. O servidor precisa de saída HTTPS para o domínio real da Edge Function. Não abre portas de entrada e não exige VPN ou acesso direto do painel à loja.

Padrão: `C:\infra-monitor-unificado`. Configuração, identidade, logs, estado, backups e ferramentas vivem nessa raiz. Nenhum componente presume `C:\infra-monitor` ou `C:\ProgramData\InfraMonitor` como destino.

## Release e confiança

Gere o ZIP em estação Windows com `scripts/Build-Release.ps1`, ou use o ZIP desta entrega após a homologação. O pacote contém executável, scripts e manifesto SHA256 por arquivo. Publique ZIP e o SHA256 por canal administrativo confiável, por exemplo release do repositório; não existe URL de release publicada automaticamente por este trabalho.

SHA256 fixado protege contra substituição do pacote; obter o hash por um canal administrativo confiável, não do mesmo download não confiável. TLS e validação de certificados permanecem ativos. Não usar `iex` em conteúdo de rede ou desabilitar TLS/checagem de hash.

## Instalação nova

No painel v2, cadastrar loja e hostname. Guardar o código de uso único, válido por 30 minutos. O token individual é emitido pelo backend, não criado pelo instalador. Não há token administrativo nos servidores.

Com pacote ZIP já verificado e extraído, uma linha no PowerShell administrativo:

```powershell
& 'C:\Pacotes\InfraMonitor-2.0.0\scripts\Install.ps1' -ApiBaseUrl 'https://SEU-PROJETO.supabase.co/functions/v1/infra-monitor' -Mode New
```

O instalador solicita o código de forma protegida, configura serviço automático e aguarda heartbeat autenticado. A configuração exemplo usa FrCaixaMonitor e `C:\FrCaixaMonitor\monitor.exe`. Verifique e ajuste `config\agent.json` para o caminho REAL antes de liberar operações; um caminho divergente impede controle e reporta configuração desconhecida, sem executar outro binário.

Para download e instalação em uma linha, disponibilize previamente o `Bootstrap.ps1` desta release por um canal confiável:

```powershell
& 'C:\Pacotes\Bootstrap.ps1' -PackageUrl 'https://SEU-DOMINIO/InfraMonitor-2.0.0.zip' -PackageSha256 'SHA256_REAL_DA_RELEASE' -ApiBaseUrl 'https://SEU-PROJETO.supabase.co/functions/v1/infra-monitor'
```

Os valores em maiúsculas são placeholders. O script verifica SHA256 antes de executar o instalador. A raiz temporária é removida ao terminar. Via RustDesk, usar a mesma linha em sessão administrativa; não transmitir tokens em mensagens ou gravações de tela.

## Migrar os servidores atuais

1. Em UM servidor piloto, identificar a raiz real e o nome do serviço antigo. Não tentar os três diretórios por tentativa. Os formatos suportados são `host.uuid` + `host.token` na raiz antiga, ou `config\identity.json` com `host_id` e `token`. Outro formato precisa de conversão local revisada; não colar credenciais em chat.
2. Exportar apenas metadados seguros:

```powershell
& 'C:\Pacotes\InfraMonitor-2.0.0\scripts\Export-Legacy.ps1' -LegacyRoot 'C:\infra-monitor'
```

3. No painel v2, escolher o host antigo pelo UUID e cadastrar loja/hostname com o `existing_token_sha256` exportado. O backend preserva esse UUID e aceita o mesmo token. Os dados antigos continuam nas tabelas antigas; não são copiados nem removidos.
4. Migrar explicitamente:

```powershell
& 'C:\Pacotes\InfraMonitor-2.0.0\scripts\Install.ps1' -ApiBaseUrl 'https://SEU-PROJETO.supabase.co/functions/v1/infra-monitor' -Mode Migrate -LegacyRoot 'C:\infra-monitor' -LegacyServiceName 'NOME_REAL_DO_SERVICO_ANTIGO'
```

A origem fica intacta e é copiada para `backups\legacy`, com ACL restrita. O serviço antigo é parado; o novo só conclui após verificar identidade e heartbeat. Se o nome antigo já for `InfraMonitorAgent`, o instalador reaproveita o registro SCM, preservando as configurações NSSM antigas no registro para recuperação; nesse caso exige LocalSystem e wrapper Native. Se o nome for diferente, ele só é desativado após o novo confirmar comunicação. Em falha, o caminho do serviço reaproveitado é restaurado ou o novo serviço é removido, e o antigo volta a iniciar se estava em execução.

Não usar diretórios sobrepostos. Não apagar o serviço ou diretório antigo antes de homologar. Na migração de mesmo nome, testar previamente o rollback: o instalador preserva caminho e modo de inicialização, mas não captura mudanças externas concorrentes nem senhas de contas personalizadas.

## NSSM opcional

O serviço nativo é o padrão para reduzir consumo e dependências. NSSM é suportado para instalação nova ou migração com nome de serviço diferente:

```powershell
& .\scripts\Install.ps1 -ApiBaseUrl 'https://SEU-PROJETO.supabase.co/functions/v1/infra-monitor' -ServiceWrapper Nssm -NssmPath 'C:\Pacotes\nssm.exe' -NssmSha256 'SHA256_REAL_APROVADO'
```

Ou passar `-NssmUrl 'https://SEU-REPOSITORIO/nssm.exe'` em vez de NssmPath. O download é automático quando necessário. O SHA256 é obrigatório antes da execução. Não há hash inventado ou URL de fornecedor presumida. Use binário NSSM homologado, em formato EXE (não ZIP). Fica permanentemente em `tools\nssm.exe`; o serviço usa reinício com atraso e diretório correto. Incluir o consumo do NSSM na medição.

## Recuperar instalação interrompida

O cadastro pendente fica em `config\enrollment.pending.json`, com ACL restrita. O backend permite repetir o MESMO request_id por 15 minutos após consumo para recuperar resposta perdida. Não emitir outro cadastro por tentativa.

```powershell
& .\scripts\Install.ps1 -ApiBaseUrl 'https://SEU-PROJETO.supabase.co/functions/v1/infra-monitor' -Resume
```

`-Resume` permite usar a raiz parcial e reutiliza identidade ou cadastro pendente. Se a janela de recuperação expirar sem identidade salva, o backend não devolve o token por uma requisição diferente: um administrador precisa realizar recuperação/rotação por procedimento separado. Essa rotação deliberada não é automatizada nesta versão. Não apagar identidades existentes para contornar um 401/406.

## Catálogo e saúde

Editar `config\agent.json` como administrador e reiniciar `InfraMonitorAgent`. Cada item tem `id`, `kind` (`service`/`process`), `executable` absoluto, `allowed_operations` e `allow_force`. Serviços têm `service_name` e, opcionalmente, `display_name_pattern` (substring, descoberta deve retornar exatamente um). Nome e caminho real devem coincidir. A opção `health_tcp_port` verifica serviço local TCP; omitida, saúde é `unknown` mesmo com processo ativo.

Para processos independentes, start não recebe argumentos remotos; stop/restart exige encerramento normal via janela. Aplicações de console sem janela devem ser gerenciadas como serviço. `kill` só funciona quando incluído nas operações E `allow_force=true`; valida PID, criação e caminho antes de encerrar. Não existe fallback automático de restart para kill. Processos com GUI rodam na sessão do serviço (sessão 0); não é um mecanismo de abrir aplicativos no desktop do usuário.

## Atualização e rollback

Não reinstalar nem emitir código de cadastro:

```powershell
& 'C:\infra-monitor-unificado\scripts\Update.ps1' -PackageUrl 'https://SEU-DOMINIO/InfraMonitor-2.0.1.zip' -PackageSha256 'SHA256_REAL_DA_NOVA_RELEASE'
```

Só aceita versão superior. Verifica ZIP e manifesto, faz backup de binário/scripts/configuração, para o serviço, troca arquivos e aguarda heartbeat da nova versão. Configuração, token e diário de comandos não são sobrescritos. Se falhar, restaura binário/scripts anteriores e confirma heartbeat antigo. Se também falhar, o erro permanece visível e os backups são mantidos; requer intervenção, não declara sucesso.

Para rollback manual, parar o serviço, restaurar `bin`, `scripts` e `manifest.json` de um backup aprovado e reiniciar. Não restaurar `state\commands` para uma versão antiga: isso poderia permitir repetir operações já executadas. Restaurar configuração somente se necessário, preservando a identidade vigente. Remover releases antigas/backups apenas por retenção administrativa após homologação.

## RAM e desempenho

Rodar por 65 minutos, incluindo coleta horária e um comando controlado:

```powershell
& 'C:\infra-monitor-unificado\scripts\Measure-Agent.ps1' -Minutes 65
```

Critérios: serviço presente durante toda a medição; working set e privados <100 MB em todas as amostras; preferência <50 MB. A ferramenta de medição é outro processo PowerShell temporário e não integra o consumo do agente. CSV em `logs\memory-measurement.csv`. Amostragem de um segundo não prova ausência de picos mais curtos; para qualificação final, complementar com PerfMon. Os limiares preventivos do agente são observados a cada 10 segundos e podem provocar reinício: são recuperação, não garantia de teto rígido.
