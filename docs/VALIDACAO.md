# Relatório da entrega 2.0.0

## Executado neste ambiente Linux

- 31 testes Node/TypeScript: contratos, validação, enrollment/HMAC e banco PostgreSQL local WASM/PGlite. Incluem reentrega, resultado repetido, isolamento, fila única, grants/RLS, preservação de host legado e restrição de RPC sob defaults semelhantes aos do Supabase. **31 passaram; 0 falharam; 0 pulados.**
- 21 testes C# do núcleo, executados pelo runtime PowerShell 7/.NET Core com substitutos que recusam chamadas Windows: JSON, HTTPS obrigatório, classificação de erros, intervalos, escrita atômica, deduplicação, queda/reinício, confirmação, hash e rotação de logs. **21 passaram.**
- 5 verificações PowerShell de scripts: argumentos SCM com espaços (SCM substituído), AST de 12 scripts, persistência atômica, importação de identidade e recusa de identidade incompleta. **5 passaram.**
- Total: **57 cenários/verificações passaram**. Nenhuma contagem inclui testes Windows reais.
- `npm run typecheck`: passou para backend e componente React.
- Compilação completa de produção com referências oficiais .NET Framework 4.7.2 e linguagem C# 5, plataforma x86: passou. Executável PE32/.NET gerado; ele NÃO foi executado no Windows neste ambiente.
- `npm audit`: 0 vulnerabilidades reportadas na consulta desta entrega.
- `scripts/cloud-install.sh`: instalação repetível com lockfile e execução dos checks acima passou nesta máquina.

A fixture de banco tem somente campos existentes documentados/necessários, não é uma cópia da produção. A migração foi executada apenas nesse banco local isolado. Testes do núcleo usam serialização System.Text.Json no runtime de teste; o executável Framework usa JavaScriptSerializer, validado por compilação, não por execução neste ambiente.

## Não executado / pendências de homologação

- Publicação da Edge Function, frontend e migração no Lovable real.
- Requisições autenticadas ao ambiente publicado e causa do HTTP 406 antigo.
- Instalação como serviço, NSSM, ACLs Windows, WMI e coleta real de CPU/RAM/discos.
- Start/stop/restart/kill de FrCaixaMonitor ou outro serviço/processo real.
- Migração de arquivos reais, reboot Windows, atualização e rollback reais.
- **RAM <50 MB preferencial / <100 MB obrigatória:** arquitetura preparada e ferramenta de medição entregue; nenhum pico real foi medido no Windows.
- Interação do componente em navegador e integração com o roteador real do Lovable.
- Alertas Teams e adaptação do cron antigo para hosts migrados.

A chamada não autenticada inicial para a rota antiga foi bloqueada no túnel do proxy com 403; não é evidência de resposta do aplicativo. Nenhum token foi rotacionado e nenhuma mudança foi aplicada no banco ou nas lojas.

## Diagnóstico e decisões

O código anterior não foi fornecido. A reconstrução nova foi autorizada pelo usuário e não mantém a estrutura antiga. O contrato v2 é entregue explicitamente como novo e precisa de deploy. A migração preserva UUID/token local por importação do hash no backend novo; não interpreta tabelas antigas de credenciais desconhecidas.

O runtime mudou de PowerShell persistente para C#/.NET Framework x86 para favorecer a meta de memória. PowerShell continua nos instaladores e ferramentas. A execução nativa como serviço evita a dependência extra de NSSM por padrão; NSSM continua disponível com download e hash exigido.

Não há garantia de execução exatamente uma vez em toda falha possível: um comando com intenção persistida e resultado incerto não é repetido automaticamente. O painel deve orientar reconciliação manual pelo estado observado.

## Próximo passo

Aplicar a integração de `docs/LOVABLE.md` em homologação e executar toda a matriz de `docs/TESTES-WINDOWS.md` em um servidor piloto. Só promover para as demais lojas depois de confirmar memória, migração, atualização e operações no ambiente real.

## Atualização 2.0.1 (30/10/2026)

27 testes do núcleo e 6 verificações dos scripts passaram. O código de produção foi compilado contra .NET Framework 4.7.2/C# 5/x86. Novidade: observador por nome de monitor.exe, catálogo sem controle remoto e guarda ERP/PDV no runtime. Logs de API incluem status numérico. A homologação Windows e RAM continuam pendentes. Ver INSTALACAO-WEB.md.
