using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
namespace Uffa.InfraMonitor {
// Bounded streaming capture: retain the terminal stdout record even after megabytes of logs.
public sealed class CleanupOutput {
    readonly StringBuilder firstOutput=new StringBuilder(),firstError=new StringBuilder(),line=new StringBuilder();
    bool overflow;public string ResultLine {get;private set;}
    static void Prefix(StringBuilder buffer,char[] chars,int count){int take=Math.Min(500-buffer.Length,count);if(take>0)buffer.Append(chars,0,take);}
    public void AppendOutput(char[] chars,int count){Prefix(firstOutput,chars,count);for(int i=0;i<count;i++){char c=chars[i];if(c=='\r'||c=='\n'){FinishLine();continue;}if(line.Length<1024&&!overflow)line.Append(c);else overflow=true;}}
    public void AppendError(char[] chars,int count){Prefix(firstError,chars,count);}
    void FinishLine(){if(!overflow&&line.ToString().TrimStart().StartsWith("[OTM_RESULT]",StringComparison.Ordinal))ResultLine=line.ToString().Trim();line.Length=0;overflow=false;}
    public void Finish(){FinishLine();}
    public string Error {get{return firstError.Length>0?firstError.ToString():firstOutput.ToString();}}
}
public static class SystemCleanup {
    public const string ScriptUrl="https://raw.githubusercontent.com/fromNexz/UFFA/refs/heads/main/otm/otimizar.ps1";
    public const int TimeoutSeconds=960;
    public const string TimeoutMessage="Tempo limite de 15 minutos excedido durante a limpeza do sistema.";
    static readonly Regex result=new Regex(@"^\[OTM_RESULT\]\s+STATUS=(?<status>[A-Z_]{1,32})\s*\|\s*LIBERADO_MB=(?<mb>-?[0-9]{1,20}(?:[.,][0-9]{1,6})?)\s*\|\s*LIVRE_ATUAL_GB=(?<gb>[0-9]{1,20}(?:[.,][0-9]{1,6})?)\s*\|\s*TEMPO_SEG=(?<seconds>[0-9]{1,20}(?:[.,][0-9]{1,6})?)\s*$",RegexOptions.CultureInvariant);
    public static ScriptRequest Request(){return new ScriptRequest{Target="powershell",Timeout=TimeoutSeconds,WorkingDirectory=Path.GetTempPath(),Script="$ErrorActionPreference='Stop'; $OutputEncoding=[Console]::OutputEncoding; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; try { irm '"+ScriptUrl+"' -TimeoutSec 60 -ErrorAction Stop | iex } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }"};}
    public static string Execute(Func<bool> cancelled){return Run((request,stdout,stderr)=>NativeScriptRunner.Run(request,cancelled,stdout,stderr));}
    public static string Run(Func<ScriptRequest,Action<char[],int>,Action<char[],int>,ScriptExit> execute){
        try{
            var output=new CleanupOutput();var exit=execute(Request(),output.AppendOutput,output.AppendError);output.Finish();
            if(exit.Cancelled)throw new MaintenanceFailure("Falha ao executar limpeza: cancelada pela parada do agente.");
            var match=result.Match(output.ResultLine??"");string status=match.Success?match.Groups["status"].Value:"";
            // Never confirm success from a stale record if the process was killed or exited with failure.
            if(exit.TimedOut){if(status=="ERRO"||status=="TIMEOUT")throw StatusFailure(status,match);throw new MaintenanceFailure(TimeoutMessage);}
            if(exit.Code!=0)throw Failure(String.IsNullOrWhiteSpace(output.Error)?"PowerShell encerrou com código "+exit.Code+".":output.Error);
            if(!match.Success)throw Failure(String.IsNullOrWhiteSpace(output.Error)?"O script não emitiu um resumo [OTM_RESULT] válido.":"Resumo [OTM_RESULT] ausente ou inválido. "+output.Error);
            if(status!="OK"&&status!="PARCIAL")throw StatusFailure(status,match);
            return "Limpeza concluída ("+status+"). "+Number(match,"mb")+" MB liberados (Livre atual: "+Number(match,"gb")+" GB) em "+Number(match,"seconds")+"s.";
        }catch(MaintenanceFailure){throw;}catch(Exception e){throw Failure(e.Message);}
    }
    static string Number(Match match,string key){return match.Groups[key].Value.Replace(',','.');}
    static MaintenanceFailure StatusFailure(string status,Match match){return new MaintenanceFailure("Limpeza falhou com status "+status+" após "+Number(match,"seconds")+"s.");}
    static MaintenanceFailure Failure(string error){return new MaintenanceFailure("Falha ao executar limpeza: "+error.Replace('\0',' ').Trim());}
}
}
