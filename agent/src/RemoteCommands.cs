using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
namespace Uffa.InfraMonitor {
public sealed class MaintenanceFailure:Exception {
    public MaintenanceFailure(string message):base(message.Length>500?message.Substring(0,500):message){}
}
// ServiceControllerStatus numeric values. Delegates keep transitions testable without SCM.
public static class ServiceTransition {
    static bool Pending(int state){return state==2||state==3||state==5||state==6;}
    public static void Apply(bool start,Func<int> read,Action issue,Func<bool> canStop,Action<int> wait) {
        int state=read(),count=0,desired=start?4:1;
        while(Pending(state)&&count++<125){wait(200);state=read();}
        if(Pending(state))throw new MaintenanceFailure("Servico permaneceu em transicao por 25s; nenhuma nova ordem enviada.");
        if(state==desired)return;
        if(!start&&!canStop())throw new MaintenanceFailure("Servico nao aceita parada no estado atual; processos preservados.");
        try{issue();}catch(InvalidOperationException){if(read()==desired)return;throw;}
        count=0;while((state=read())!=desired&&count++<125)wait(200);
        if(state!=desired)throw new MaintenanceFailure(start?"Servico nao confirmou inicializacao em 25s.":"Servico nao confirmou parada em 25s.");
    }
}
public static class MaintenancePolicy {
    public static string ActionFailure(string operation,string stage,Exception error) {
        var native=error;int? win32=null;for(int depth=0;native!=null&&depth<8;depth++,native=native.InnerException){var value=native as System.ComponentModel.Win32Exception;if(value!=null){win32=value.NativeErrorCode;break;}}
        string code=win32.HasValue?"Win32="+win32.Value:"HRESULT=0x"+error.HResult.ToString("X8");
        return "Acao "+operation+" falhou na etapa "+stage+" ("+error.GetType().Name+"; "+code+"). Nenhuma credencial foi alterada.";
    }
    public const string RustDeskPath=@"C:\Program Files\RustDesk\RustDesk.exe";
    public static string FullLocalExe(string value) {
        if(value.Length<4||!Char.IsLetter(value[0])||value[1]!=':'||value[2]!='\\'||!value.EndsWith(".exe",StringComparison.OrdinalIgnoreCase)||value.IndexOfAny(new[]{'"','\r','\n'})>=0||value.Contains(".."))throw new MaintenanceFailure("Executavel local absoluto invalido.");
        string name=value.Replace('\\','/');name=name.Substring(name.LastIndexOf('/')+1);
        if(name.Equals("powershell.exe",StringComparison.OrdinalIgnoreCase)||name.Equals("cmd.exe",StringComparison.OrdinalIgnoreCase)||name.Equals("pwsh.exe",StringComparison.OrdinalIgnoreCase))throw new MaintenanceFailure("Interpretador de comandos nao e um aplicativo autorizado.");return value;
    }
    public static bool RelatedFrProcess(string mainExe,string processPath,string processName) {
        FullLocalExe(mainExe);if(String.IsNullOrEmpty(processPath))return false;
        string normalized=mainExe.Replace('\\','/'),actual=processPath.Replace('\\','/');string dir=normalized.Substring(0,normalized.LastIndexOf('/')+1);
        if(!actual.StartsWith(dir,StringComparison.OrdinalIgnoreCase))return false;
        string tail=actual.Substring(dir.Length);if(tail.IndexOf('/')>=0)return false;
        return processName.Equals("frcaixa.exe",StringComparison.OrdinalIgnoreCase)||processName.Equals("monitor.exe",StringComparison.OrdinalIgnoreCase)||processName.Equals("monitorthread.exe",StringComparison.OrdinalIgnoreCase)||actual.Equals(normalized,StringComparison.OrdinalIgnoreCase);
    }
    public static bool ExpiredTemp(DateTime createdUtc,DateTime writtenUtc,DateTime nowUtc) {return createdUtc<nowUtc.AddHours(-24)&&writtenUtc<nowUtc.AddHours(-24);}
    public static string NormalPath(string path){if(path.StartsWith(@"\\?\",StringComparison.Ordinal))path=path.Substring(4);return path.Replace('/','\\').TrimEnd('\\');}
    public static bool BelowRoot(string root,string candidate){return NormalPath(candidate).StartsWith(NormalPath(root)+"\\",StringComparison.OrdinalIgnoreCase);}
    public static int ChooseSession(int console,IList<int> active) {if(console>0&&active.Contains(console))return console;if(active.Count==1&&active[0]>0)return active[0];throw new MaintenanceFailure("Nenhuma sessao interativa ativa univoca; nenhum aplicativo foi encerrado.");}
    public static Dictionary<string,object> Authorize(object[] catalog,Dictionary<string,object>command) {
        string id=Json.Str(command,"target_id"),op=Json.Str(command,"operation");Dictionary<string,object>t=null;int count=0;
        foreach(object value in catalog){var candidate=Json.Obj(value);if(Json.Str(candidate,"id")==id){t=candidate;count++;}}
        if(count!=1)throw new MaintenanceFailure("Alvo ausente ou duplicado no catalogo local.");
        bool allowed=false;foreach(object v in Json.Array(t,"allowed_operations"))if(Convert.ToString(v)==op)allowed=true;
        if(!allowed)throw new MaintenanceFailure("Operacao nao autorizada no catalogo local.");
        if(id=="frcaixa") {if(!Json.Bool(t,"remote_control_enabled"))throw new MaintenanceFailure("FrCaixa configurado somente para monitoramento.");if(op!="start"&&op!="stop"&&op!="restart"&&op!="kill")throw new MaintenanceFailure("Operacao FrCaixa invalida.");FullLocalExe(Json.Str(t,"executable"));if(op=="kill"&&!Json.Bool(t,"allow_force"))throw new MaintenanceFailure("Encerramento forcado nao autorizado.");}
        else if(id=="rustdesk") {if(!String.Equals(Json.Str(t,"executable"),RustDeskPath,StringComparison.OrdinalIgnoreCase))throw new MaintenanceFailure("Caminho RustDesk diverge do caminho fixo autorizado.");if(op!="start"&&op!="stop"&&op!="restart"&&op!="kill")throw new MaintenanceFailure("Operacao RustDesk invalida.");if(!Json.Bool(t,"allow_force"))throw new MaintenanceFailure("Reinicio RustDesk exige allow_force local.");}
        else if(id=="system_cleanup") {if(op!="start")throw new MaintenanceFailure("Limpeza aceita somente start.");}
        else if(ScriptExecution.IsTarget(id)){if(op!="start")throw new MaintenanceFailure("Execucao de script aceita somente start.");}
        else throw new MaintenanceFailure("Alvo de manutencao desconhecido.");return t;
    }
    public static Dictionary<string,object> BindCommand(Dictionary<string,object>remote,string hostId,DateTime? now=null) {
        var c=new Dictionary<string,object>();foreach(string key in new[]{"id","host_id","target_id","operation","expires_at","reason"})if(remote.ContainsKey(key))c[key]=remote[key];Guid id;if(!Guid.TryParse(Json.Str(c,"id"),out id))throw new InvalidDataException("ID de comando invalido.");
        string destination=Json.Str(c,"host_id");if(destination!=""&&!destination.Equals(hostId,StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("Comando de outro host.");
        // Called only for the authenticated, host-scoped HTTPS pull response. Never for arbitrary input.
        c["host_id"]=hostId;c["id"]=id.ToString();
        if(Json.Str(c,"expires_at")=="")c["expires_at"]=(now??DateTime.UtcNow).AddMinutes(5).ToString("o");
        return c;
    }
}
public sealed class RemoteCommandWorker:IDisposable {
    sealed class Item {public Dictionary<string,object> Command;public long Received;}
    readonly Queue<Item> queue=new Queue<Item>();readonly HashSet<string> active=new HashSet<string>();readonly object gate=new object();
    readonly AutoResetEvent signal=new AutoResetEvent(false);readonly Thread thread;readonly CommandJournal journal;readonly string host;
    readonly Func<DateTime> utcNow;readonly Func<Dictionary<string,object>,string> execute;readonly Action<Dictionary<string,object>> confirm;readonly Action<string> log;
    bool closing;int completed;
    public RemoteCommandWorker(CommandJournal j,string h,Func<Dictionary<string,object>,string> action,Action<Dictionary<string,object>> send,Action<string> logger,Func<DateTime> clock=null) {
        journal=j;host=h;utcNow=clock??(()=>DateTime.UtcNow);execute=action;confirm=send;log=logger;thread=new Thread(Loop){IsBackground=true,Name="InfraMonitor-Maintenance",Priority=ThreadPriority.BelowNormal};
#if !PORTABLE_TEST
        thread.SetApartmentState(ApartmentState.STA);
#endif
        thread.Start();
    }
    public bool Enqueue(Dictionary<string,object>remote) {
        var cmd=MaintenancePolicy.BindCommand(remote,host,utcNow());string id=Json.Str(cmd,"id");
        lock(gate){if(closing||active.Contains(id)||queue.Count>=8)return false;active.Add(id);queue.Enqueue(new Item{Command=cmd,Received=Stopwatch.GetTimestamp()});signal.Set();return true;}
    }
    public bool TakeCompleted(){return Interlocked.Exchange(ref completed,0)!=0;}
    void Loop(){
        try{while(true){Item item=null;lock(gate){if(closing)return;if(queue.Count>0)item=queue.Dequeue();}if(item==null){signal.WaitOne();continue;}
            try{
                bool stale=(Stopwatch.GetTimestamp()-item.Received)/(double)Stopwatch.Frequency>300;
                var record=journal.Execute(item.Command,c=>{if(stale)throw new MaintenanceFailure("Comando aguardou mais de 5 minutos na fila local.");return execute(c);});
                try{confirm(record);}catch{log("command_result_deferred");}
            }catch{log("command_worker_failed");}
            finally{lock(gate)active.Remove(Json.Str(item.Command,"id"));Interlocked.Exchange(ref completed,1);}
        }}finally{signal.Dispose();}
    }
    public void Dispose(){lock(gate){if(closing)return;closing=true;signal.Set();}thread.Join(3000);}
}
}
