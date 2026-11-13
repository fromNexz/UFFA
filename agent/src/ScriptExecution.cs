using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
namespace Uffa.InfraMonitor {
public sealed class ScriptResultFailure:Exception {public ScriptResultFailure(string message):base(message){} }
public sealed class ScriptRequest {
    public string Target,Script,WorkingDirectory;public int Timeout=60;
    public static ScriptRequest Parse(Dictionary<string,object> command) {
        string target=Json.Str(command,"target_id");if(!ScriptExecution.IsTarget(target)||Json.Str(command,"operation")!="start")throw new InvalidDataException("Script aceita somente start em powershell ou cmd.");
        object supplied=Json.Get(command,"reason");if(!(supplied is string))throw new InvalidDataException("reason deve ser texto.");string reason=(string)supplied;if(reason.Length>16000)throw new InvalidDataException("reason excede 16000 caracteres.");
        var r=new ScriptRequest{Target=target,WorkingDirectory=Path.GetTempPath()};string trimmed=reason.TrimStart();
        if(trimmed.StartsWith("{")) {
            Dictionary<string,object> body=null;try{body=Json.Obj(Json.Parse(reason));}catch{if(System.Text.RegularExpressions.Regex.IsMatch(trimmed,"^\\{\\s*\""))throw new InvalidDataException("JSON de reason invalido; nenhuma instrucao executada.");r.Script=reason;}
            if(body!=null){object raw=Json.Get(body,"script");if(!(raw is string))throw new InvalidDataException("script deve ser texto.");r.Script=(string)raw;
            if(body.ContainsKey("timeout")){raw=body["timeout"];if(!(raw is int||raw is long||raw is double||raw is decimal))throw new InvalidDataException("timeout deve ser inteiro positivo.");double n=Convert.ToDouble(raw,CultureInfo.InvariantCulture);if(Double.IsNaN(n)||n<1||n>Int32.MaxValue||n!=Math.Floor(n))throw new InvalidDataException("timeout deve ser inteiro positivo.");r.Timeout=(int)n;}
            if(body.ContainsKey("working_dir")&&body["working_dir"]!=null){if(!(body["working_dir"] is string))throw new InvalidDataException("working_dir deve ser texto.");if(Json.Str(body,"working_dir")!="")r.WorkingDirectory=Environment.ExpandEnvironmentVariables(Json.Str(body,"working_dir"));}
            }
        } else r.Script=reason;
        if(String.IsNullOrWhiteSpace(r.Script)||r.Script.Length>12000||r.Script.IndexOf('\0')>=0)throw new InvalidDataException("Script vazio, com NUL ou maior que 12000 caracteres.");
        if(r.WorkingDirectory.IndexOf('\0')>=0)throw new InvalidDataException("working_dir invalido.");return r;
    }
    public string Arguments {get{return Target=="powershell"?"-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "+Quote("& { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "+Script+" }"):"/d /c \""+Script+"\"";}}
    // Windows argv quoting: preserve quotes, backslashes and newlines inside the single -Command argument.
    public static string Quote(string value){var b=new StringBuilder("\"");int slashes=0;foreach(char c in value){if(c=='\\'){slashes++;continue;}if(c=='"'){b.Append('\\',slashes*2+1).Append(c);slashes=0;continue;}b.Append('\\',slashes).Append(c);slashes=0;}return b.Append('\\',slashes*2).Append('"').ToString();}
}
public sealed class ScriptOutput {
    readonly StringBuilder text=new StringBuilder();bool truncated;
    public void Append(char[] chars,int count){int take=Math.Min(1800-text.Length,count);if(take>0)text.Append(chars,0,take);if(take<count)truncated=true;}
    public string Text {get{int length=text.Length;if(truncated&&length>0&&Char.IsHighSurrogate(text[length-1]))length--;return text.ToString(0,length)+(truncated?"[... truncado]":"");}}
}
public sealed class ScriptExit {public int Code;public string Output;public bool TimedOut,Cancelled;}
public static class ScriptExecution {
    public static bool IsTarget(string id){return id=="powershell"||id=="cmd";}
    public static object[] WithCatalog(object[] catalog){var result=new List<object>();foreach(object raw in catalog)if(!IsTarget(Json.Str(Json.Obj(raw),"id")))result.Add(raw);foreach(string id in new[]{"powershell","cmd"})result.Add(new Dictionary<string,object>{{"id",id},{"kind","process"},{"allowed_operations",new object[]{"start"}},{"allow_force",false}});if(result.Count>66)throw new InvalidDataException("Catalogo excede 66 alvos incluindo powershell/cmd.");return result.ToArray();}
    public static string Execute(Dictionary<string,object> command,Func<bool> cancelled){return Run(command,r=>NativeScriptRunner.Run(r,cancelled));}
    public static string Run(Dictionary<string,object> command,Func<ScriptRequest,ScriptExit> execute){
        try {var r=ScriptRequest.Parse(command);var exit=execute(r);if(exit.TimedOut)throw new ScriptResultFailure("[Timeout "+r.Timeout+"s] O comando excedeu o tempo limite e foi cancelado pelo agente.");if(exit.Cancelled)throw new ScriptResultFailure("[Cancelado] O comando foi cancelado pela parada do agente.");
            string output=exit.Output??"";if(output.Length>1814)output=output.Substring(0,1800)+"[... truncado]";string message="[Exit "+exit.Code+"]\n"+output;if(exit.Code!=0)throw new ScriptResultFailure(message);return message;
        }catch(ScriptResultFailure){throw;}catch(Exception e){string message="[Erro "+e.GetType().Name+"] "+e.Message;if(message.Length>1900)message=message.Substring(0,1900);throw new ScriptResultFailure(message);}
    }
}
}
