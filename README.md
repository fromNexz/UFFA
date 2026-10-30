# Infra Monitor UFFA 2.0.1

Nova implementação para monitorar lojas Windows e receber operações administrativas por consulta HTTPS. Desenvolvida a partir da documentação Lovable fornecida, sem os códigos antigos. Não aplica alterações no banco ou nos servidores automaticamente.

## O que está incluído

- Agente compilável C# 5 / .NET Framework 4.7.2, executável x86 para reduzir o custo do runtime. Serviço Windows nativo por padrão; suporte opcional a NSSM com hash obrigatório.
- PowerShell 5.1 para instalação, migração, atualização, rollback automático e medição de RAM.
- Backend Supabase Edge Function v2 e migração SQL aditiva `im_*`, sem recriar tabelas antigas.
- Componente React administrativo com cadastro, vínculo com hosts existentes, IPs, intervalos, estado de processos, comandos e auditoria.
- Testes do núcleo, contratos, autenticação de operações no banco, isolamento, RLS e deduplicação.

**RAM:** meta preferencial menor que 50 MB; critério obrigatório menor que 100 MB, tanto working set quanto memória privada, incluindo NSSM se usado. Ainda não medido no Windows. Existe reinício preventivo ao observar 80 MB privados ou 90 MB de working set; isso NÃO é um limite rígido do sistema operacional nem prova de atendimento. Medir por pelo menos 65 minutos antes de distribuir.

## Instalação rápida atual

Use o iniciador web descrito em [INSTALACAO-WEB.md](docs/INSTALACAO-WEB.md). O agente atual observa o FrCaixaMonitor/monitor.exe **somente para leitura**, sem operações de controle. Pacotes 2.0.0 e documentação de entrega original permanecem como histórico; o pacote novo é 2.0.1. Instalações já existentes não são substituídas automaticamente pelo iniciador.

## Começar

1. Integrar os arquivos em `lovable/` conforme [guia do Lovable](docs/LOVABLE.md). A Edge Function v2 precisa ser publicada antes de cadastrar agentes.
2. Usar o novo painel para criar uma loja ou vincular um dos hosts existentes. A imagem do banco fornecida mostra 16 hosts; nenhum deles foi alterado por esta entrega.
3. No Windows administrativo, usar o pacote de release verificado e seguir [instalação e migração](docs/INSTALACAO.md).
4. Fazer os [testes Windows](docs/TESTES-WINDOWS.md), incluindo medição de RAM, antes de expandir para as 25 lojas.

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `agent/src/` | Runtime leve: HTTPS, persistência, scheduler, coletores e catálogo |
| `agent/config/agent.example.json` | Única configuração local, sem tokens |
| `scripts/Install.ps1` | Instalação nova ou migração com backup |
| `scripts/Bootstrap.ps1` | Download HTTPS e instalação de pacote com SHA256 fixado |
| `scripts/Update.ps1` | Atualização versionada e rollback automático |
| `scripts/Export-Legacy.ps1` | Exporta somente UUID e SHA256 para vínculo no painel |
| `scripts/Measure-Agent.ps1` | Teste de memória em Windows |
| `lovable/supabase/` | Backend novo e migração a revisar |
| `lovable/frontend/InfraMonitorPanel.tsx` | Painel administrativo integrável |
| `tests/` | Testes do núcleo e de banco local isolado |

## Frequências padrão

Métricas, IPs e processos: 3600 segundos, independentemente. Consulta leve: 60 segundos. Heartbeat: 300 segundos. Resultado de comando é enviado imediatamente após a execução. Se falhar, fica na fila persistente e a confirmação é repetida a cada ciclo de 15 segundos, sem repetir a ação. As configurações remotas alteram somente os intervalos e os IPs. Executáveis e permissões ficam no catálogo local.

O coletor executa em um único worker; as sondagens são sequenciais (concorrência 1), com timeout individual. Heartbeat e comandos usam o loop principal. Cada IP pode sobrescrever o intervalo padrão da loja; resultados em cache preservam a data individual da última sonda. Máximo de 128 IPs por host, 32 portas por IP e 64 alvos locais. Para uma lista grande de IPs, o ciclo pode demorar: dimensionar timeouts e quantidade no teste de homologação.

Conectividade vem do heartbeat recebido pelo servidor, com tolerância de três intervalos (15 minutos por padrão), não da coleta horária. O painel mostra datas separadas e marca coletas antigas.

## Desenvolvimento

```sh
npm ci --cache /workspace/.cache/npm
npm test
npm run typecheck
```

`npm` é ferramenta de desenvolvimento do backend/painel; NÃO é instalado nas lojas. Os testes de banco usam PostgreSQL WASM/PGlite isolado, com fixture mínima do schema existente; não acessam produção.

Em PowerShell 7 (Linux ou Windows), ou Windows PowerShell 5.1:

```powershell
.\tests\Run-AgentTests.ps1
```

No Windows com .NET 4.7.2+:

```powershell
.\scripts\Build-Release.ps1
```

A compilação é feita com `csc.exe` distribuído com o .NET Framework, sem SDK nem NuGet no servidor. Use uma estação de build, não cada loja, para gerar o pacote versionado.

## Limites desta entrega

Compilação e testes locais não equivalem a instalação ou integração publicada. Ver [relatório de validação](docs/VALIDACAO.md). Não houve acesso ao código anterior, ao schema completo, a Windows real ou ao backend publicado. Não há rotas em produção comprovadas. Não foram aplicadas migrações. Alertas Teams e automação antiga exigem adaptação do código Lovable existente para excluir hosts migrados; não estão validados nem reimplementados aqui.
