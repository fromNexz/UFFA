$ErrorActionPreference='Stop'
$scriptPath=Join-Path $PSScriptRoot 'Remover-InfraMonitor-Antigo.ps1'
$errors=$null;$tokens=$null
[void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if ($errors) { throw ($errors|Out-String) }
. $scriptPath
$count=0
function Check([string]$Name,[bool]$Value) { if (!$Value) { throw "FAIL: $Name" };$script:count++;Write-Host "PASS: $Name" }
Check 'Coletor ProgramData' (Test-ScriptAntigo 'powershell.exe -NoProfile -File "C:\ProgramData\InfraMonitor\collect.ps1" -ConfigPath x')
Check 'Watchdog ProgramData' (Test-ScriptAntigo '-File C:\ProgramData\InfraMonitor\watchdog.ps1')
Check 'Agente antigo bin' (Test-ScriptAntigo '-NoProfile -File "C:\ProgramData\InfraMonitor\bin\agent.ps1"')
Check 'Raiz personalizada C infra-monitor' (Test-ScriptAntigo '-File C:\infra-monitor\bin\agent.ps1')
Check 'Capitalizacao independente' (Test-ScriptAntigo '-FILE "c:\INFRA-MONITOR\AGENT\COLLECT.PS1"')
Check 'Prefixo parecido nao e alvo' (!(Test-ScriptAntigo '-File C:\infra-monitor-outra\bin\agent.ps1'))
Check 'Agente novo preservado' (!(Test-ScriptAntigo '-File C:\infra-monitor-unificado\bin\agent.ps1'))
Check 'Script nao relacionado preservado' (!(Test-ScriptAntigo '-File C:\outro\watchdog.ps1'))
Check 'Monitor de negocio preservado' (!(Test-ScriptAntigo '-File C:\FrCaixaMonitor\monitor.ps1'))
Check 'Caminho mencionado como dado nao e execucao' (!(Test-ScriptAntigo '-Command Get-Content C:\infra-monitor\bin\agent.ps1'))
Check 'Sufixo de arquivo rejeitado' (!(Test-ScriptAntigo '-File C:\infra-monitor\bin\agent.ps1.bak'))
Check 'Wrapper cmd antigo' (Test-WrapperAntigo 'cmd.exe /c C:\ProgramData\InfraMonitor\bin\agent.cmd')
Check 'Wrapper duplamente entre aspas' (Test-WrapperAntigo 'cmd.exe /c ""C:\ProgramData\InfraMonitor\bin\agent.cmd""')
Check 'Wrapper novo preservado' (!(Test-WrapperAntigo 'cmd.exe /c C:\infra-monitor-unificado\bin\agent.cmd'))
$svc=[pscustomobject]@{PathName='cmd.exe /c C:\ProgramData\InfraMonitor\bin\agent.cmd'}
Check 'Servico wrapper identificado' (Test-ServicoAntigo $svc '' '')
$svc.PathName='C:\tools\nssm.exe'
Check 'NSSM de coletor identificado pelos parametros' (Test-ServicoAntigo $svc 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' '-File "C:\ProgramData\InfraMonitor\collect.ps1"')
Check 'NSSM de outro aplicativo preservado' (!(Test-ServicoAntigo $svc 'C:\outro\app.exe' '-File C:\ProgramData\InfraMonitor\collect.ps1'))
Check 'NSSM novo preservado' (!(Test-ServicoAntigo $svc 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' '-File C:\infra-monitor-unificado\bin\agent.ps1'))
$task=[pscustomobject]@{TaskPath='\';TaskName='InfraMonitorWatchdog';Actions=@([pscustomobject]@{Execute='powershell.exe';Arguments='-File C:\ProgramData\InfraMonitor\watchdog.ps1'})}
Check 'Tarefa watchdog identificada' (Test-TarefaAntiga $task)
$task.Actions+= [pscustomobject]@{Execute='outro.exe';Arguments=''}
Check 'Tarefa com acoes mistas preservada' (!(Test-TarefaAntiga $task))
$task=[pscustomobject]@{TaskPath='\';TaskName='InfraMonitorDelayedStart';Actions=@([pscustomobject]@{Execute='schtasks.exe';Arguments='/Run /TN "InfraMonitorAgent"'})}
Check 'Relancador conhecido identificado' (Test-TarefaAtrasada $task $false)
Check 'Relancador de tarefa principal nova preservado' (!(Test-TarefaAtrasada $task $true))
$task.Actions[0].Arguments='/Run /TN "OutroMonitor"'
Check 'Outro alvo de tarefa preservado' (!(Test-TarefaAtrasada $task $false))
$task.Actions[0].Arguments='/Run /TN "InfraMonitorAgent" & outro.exe'
Check 'Relancador com comando extra preservado' (!(Test-TarefaAtrasada $task $false))
Check 'Texto vazio nao identifica script' (!(Test-ScriptAntigo ''))
$svc=[pscustomobject]@{Name='FrCaixaMonitor';DisplayName='FrCaixaMonitor';PathName='cmd.exe /c C:\ProgramData\InfraMonitor\bin\agent.cmd'}
Check 'Servico FrCaixa protegido mesmo com caminho misto' (!(Test-ServicoAntigo $svc '' ''))
$svc=[pscustomobject]@{Name='InfraMonitorAgent';DisplayName='Infra Monitor Agent';PathName='C:\FrCaixaMonitor\monitor.exe'}
Check 'Executavel monitor.exe nunca identifica servico agente' (!(Test-ServicoAntigo $svc '' ''))
$svc=[pscustomobject]@{Name='InfraMonitorAgent';DisplayName='Infra Monitor Agent';PathName='C:\tools\nssm.exe'}
Check 'NSSM do ERP preservado mesmo com argumentos mistos' (!(Test-ServicoAntigo $svc 'C:\FrCaixaMonitor\monitor.exe' '-File C:\ProgramData\InfraMonitor\collect.ps1'))
$task=[pscustomobject]@{TaskPath='\';TaskName='FrCaixaMonitor';Actions=@([pscustomobject]@{Execute='powershell.exe';Arguments='-File C:\ProgramData\InfraMonitor\watchdog.ps1'})}
Check 'Tarefa FrCaixa protegida explicitamente' (!(Test-TarefaAntiga $task))
Write-Host "$count testes de identificacao passaram; operacoes Windows NAO foram executadas."
