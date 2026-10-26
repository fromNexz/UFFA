param([Parameter(Mandatory=$true)][string]$ReferenceDirectory,[string]$Repository=(Split-Path $PSScriptRoot -Parent),[string]$Output)
$ErrorActionPreference='Stop'
if (!$Output) { $Output=Join-Path $Repository 'dist/package/bin/InfraMonitor.Agent.exe' }
[void][IO.Directory]::CreateDirectory((Split-Path $Output))
# Uses the compiler distributed with PowerShell 7. Targets .NET Framework refs, not .NET Core.
Add-Type -AssemblyName Microsoft.CodeAnalysis
Add-Type -AssemblyName Microsoft.CodeAnalysis.CSharp
$trees=[Collections.Generic.List[Microsoft.CodeAnalysis.SyntaxTree]]::new()
$parse=[Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::new([Microsoft.CodeAnalysis.CSharp.LanguageVersion]::CSharp5)
foreach ($file in Get-ChildItem (Join-Path $Repository 'agent/src/*.cs')) { $trees.Add([Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText([IO.File]::ReadAllText($file.FullName),$parse,$file.FullName)) }
$refs=[Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]]::new()
foreach ($name in @('mscorlib.dll','System.dll','System.Core.dll','System.Web.Extensions.dll','System.Management.dll','System.ServiceProcess.dll','System.Runtime.Serialization.dll','System.Web.dll','System.Xml.dll')) { $refs.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile((Join-Path $ReferenceDirectory $name))) }
$options=[Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::ConsoleApplication).WithPlatform([Microsoft.CodeAnalysis.Platform]::X86).WithOptimizationLevel([Microsoft.CodeAnalysis.OptimizationLevel]::Release)
$compilation=[Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('InfraMonitor.Agent',$trees,$refs,$options)
$outStream=[IO.File]::Create($Output)
try { $result=$compilation.Emit($outStream);foreach ($d in $result.Diagnostics) { Write-Host $d.ToString() };if (!$result.Success) { throw 'Compilação .NET Framework falhou.' } } finally { $outStream.Dispose() }
Write-Host "Compilado C# 5 / .NET Framework 4.7.2 / x86: $Output"
