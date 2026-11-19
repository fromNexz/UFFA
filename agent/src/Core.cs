using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading.Tasks;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
#if PORTABLE_TEST
using System.Text.Json;
#else
using System.Web.Script.Serialization;
#endif
namespace Uffa.InfraMonitor {
public static class Json {
    public static object Parse(string text) {
#if PORTABLE_TEST
        using (var doc=JsonDocument.Parse(text)) { return ConvertElement(doc.RootElement); }
#else
        return new JavaScriptSerializer { MaxJsonLength=1048576, RecursionLimit=32 }.DeserializeObject(text);
#endif
    }
#if PORTABLE_TEST
    static object ConvertElement(JsonElement e) {
        if(e.ValueKind==JsonValueKind.Object) { var d=new Dictionary<string,object>();foreach(var p in e.EnumerateObject())d[p.Name]=ConvertElement(p.Value);return d; }
        if(e.ValueKind==JsonValueKind.Array) { var a=new List<object>();foreach(var p in e.EnumerateArray())a.Add(ConvertElement(p));return a.ToArray(); }
        if(e.ValueKind==JsonValueKind.String)return e.GetString();if(e.ValueKind==JsonValueKind.Number)return e.GetDouble();if(e.ValueKind==JsonValueKind.True)return true;if(e.ValueKind==JsonValueKind.False)return false;return null;
    }
#endif
    public static string Stringify(object o) {
#if PORTABLE_TEST
        return JsonSerializer.Serialize(o);
#else
        return new JavaScriptSerializer { MaxJsonLength=1048576, RecursionLimit=32 }.Serialize(o);
#endif
    }
    public static Dictionary<string,object> Obj(object o) { var d=o as Dictionary<string,object>;if(d==null)throw new InvalidDataException("Objeto JSON esperado.");return d; }
    public static object Get(Dictionary<string,object>d,string k,object fallback=null) { object v;return d.TryGetValue(k,out v)?v:fallback; }
    public static string Str(Dictionary<string,object>d,string k,string fallback="") { return Convert.ToString(Get(d,k,fallback),CultureInfo.InvariantCulture); }
    public static int Int(Dictionary<string,object>d,string k,int fallback) { return Convert.ToInt32(Get(d,k,fallback),CultureInfo.InvariantCulture); }
    public static object[] Array(Dictionary<string,object>d,string k) { var a=Get(d,k) as object[];return a??new object[0]; }
    public static bool Bool(Dictionary<string,object>d,string k,bool fallback=false) { return Convert.ToBoolean(Get(d,k,fallback),CultureInfo.InvariantCulture); }
}
public static class CatalogPolicy {
    public static bool IsMonitorObserver(Dictionary<string,object>t) { return Json.Str(t,"kind")=="process"&&String.Equals(Json.Str(t,"process_name"),"monitor.exe",StringComparison.OrdinalIgnoreCase); }
    public static void AssertControlAllowed(Dictionary<string,object>t) {
        foreach(string key in new[]{"id","service_name","executable","process_name"}) {
            string value=Json.Str(t,key).Replace('\\','/');string name=value.Substring(value.LastIndexOf('/')+1);
            if(value.IndexOf("frcaixa",StringComparison.OrdinalIgnoreCase)>=0||String.Equals(name,"monitor.exe",StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Aplicativo ERP/PDV protegido: somente monitoramento.");
        }
        if(Json.Str(t,"process_name")!="")throw new InvalidOperationException("Observador por nome nao permite controle.");
    }
}
// Shared, portable collection rules. No wall clock is used for in-process probe cadence.
public static class CollectionPolicy {
    public static string ProbeKey(Dictionary<string,object> target) {
        IPAddress address;if(!IPAddress.TryParse(Json.Str(target,"ip"),out address))throw new InvalidDataException("IP invalido.");
        var ports=new SortedSet<int>();foreach(object raw in Json.Array(target,"tcp_ports")){int port=Convert.ToInt32(raw);if(port<1||port>65535)throw new InvalidDataException("Porta invalida.");ports.Add(port);}
        if(Json.Array(target,"tcp_ports").Length>32)throw new InvalidDataException("Portas em excesso.");
        var key=new StringBuilder(address.ToString()).Append('|');foreach(int port in ports)key.Append(":").Append(port);return key.ToString();
    }
    public static bool ServicePathMatches(string command,string expected,bool observationOnly=false) {
        command=Environment.ExpandEnvironmentVariables(command.Trim());
        if(command.StartsWith("\"")){int end=command.IndexOf('"',1);return end>0&&String.Equals(command.Substring(1,end-1),expected,StringComparison.OrdinalIgnoreCase);}
        if(!observationOnly&&expected.IndexOf(' ')>=0)return false;
        return command.StartsWith(expected,StringComparison.OrdinalIgnoreCase)&&(command.Length==expected.Length||Char.IsWhiteSpace(command[expected.Length]));
    }
    public static bool Due(double now,double last,int seconds) {return now<last||now-last>=seconds;}
    public static bool ConfirmReachability(Func<bool> attempt) {return attempt()||attempt();}
    public static long? Uptime(DateTime? start,DateTime now) {return start.HasValue&&start.Value<=now?(long?)(long)(now-start.Value).TotalSeconds:null;}
}
public static class Disk {
    public static Dictionary<string,object> Read(string path) { return Json.Obj(Json.Parse(File.ReadAllText(path))); }
    public static void Write(string path,object value) {
        Directory.CreateDirectory(Path.GetDirectoryName(path));string tmp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try {
            byte[] b=Encoding.UTF8.GetBytes(Json.Stringify(value));
            using(var f=new FileStream(tmp,FileMode.CreateNew,FileAccess.Write,FileShare.None)){f.Write(b,0,b.Length);f.Flush(true);}
            if(File.Exists(path))File.Replace(tmp,path,null);else File.Move(tmp,path);
        } finally { if(File.Exists(tmp))File.Delete(tmp); }
    }
    public static string Sha256(string text) { using(var h=SHA256.Create())return BitConverter.ToString(h.ComputeHash(Encoding.UTF8.GetBytes(text))).Replace("-","").ToLowerInvariant(); }
    public static string Now() { return DateTime.UtcNow.ToString("o"); }
}
public sealed class AgentLog {
    readonly string path;readonly object gate=new object();
    public AgentLog(string root) {path=Path.Combine(root,"logs","agent.log");Directory.CreateDirectory(Path.GetDirectoryName(path));}
    public void Event(string code) { lock(gate) {
        if(File.Exists(path)&&new FileInfo(path).Length>1048576)for(int i=4;i>=0;i--){string a=i==0?path:path+"."+i,b=path+"."+(i+1);if(File.Exists(b))File.Delete(b);if(File.Exists(a))File.Move(a,b);}
        File.AppendAllText(path,Json.Stringify(new {at=Disk.Now(),code=code})+Environment.NewLine);
    }}
}
public sealed class ApiError:Exception { public readonly int Status; public ApiError(int status):base("HTTP="+status+" "+Kind(status)){Status=status;}
    public static string Kind(int status) {switch(status){case 401:return "identity_rejected";case 403:return "forbidden";case 404:return "route_or_host_missing";case 406:return "contract_not_acceptable";case 409:return "conflict";case 429:return "rate_limited";default:return status==0||status>=500?"transient":"request_rejected";}}
}
public sealed class Api {
    readonly string baseUrl,id,token;readonly int timeout;public Func<bool> Cancelled;
    readonly object clockGate=new object();DateTime serverUtc;long serverStamp;bool hasClock;
    public void ObserveServerClock(string date){DateTimeOffset parsed;if(DateTimeOffset.TryParse(date,CultureInfo.InvariantCulture,DateTimeStyles.AssumeUniversal,out parsed))lock(clockGate){serverUtc=parsed.UtcDateTime;serverStamp=Stopwatch.GetTimestamp();hasClock=true;}}
    public DateTime ClockUtc {get{lock(clockGate){if(hasClock){double seconds=(Stopwatch.GetTimestamp()-serverStamp)/(double)Stopwatch.Frequency;if(seconds<=600)return serverUtc.AddSeconds(seconds);}return DateTime.UtcNow;}}}
    public bool LocalClockReliable {get{lock(clockGate){return hasClock&&(Stopwatch.GetTimestamp()-serverStamp)/(double)Stopwatch.Frequency<=600&&Math.Abs((ClockUtc-DateTime.UtcNow).TotalSeconds)<=300;}}}
    public Api(string url,Dictionary<string,object>identity,int timeoutSeconds=15) {
        Uri u;if(!Uri.TryCreate(url,UriKind.Absolute,out u)||u.Scheme!="https"||u.UserInfo!=""||u.Query!=""||u.Fragment!="")throw new InvalidDataException("URL HTTPS obrigatória.");
        baseUrl=url.TrimEnd('/');id=Json.Str(identity,"host_id");token=Json.Str(identity,"token");timeout=Math.Max(5,Math.Min(timeoutSeconds,30));
        ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
    }
    public HttpClient CreatePullClient() {
        var client=new HttpClient(new HttpClientHandler { AllowAutoRedirect=false, Proxy=WebRequest.DefaultWebProxy, UseProxy=true });
        client.Timeout=TimeSpan.FromSeconds(35);client.MaxResponseContentBufferSize=1048576;
        client.DefaultRequestHeaders.Accept.ParseAdd("application/json");
        client.DefaultRequestHeaders.Add("X-Host-Id",id);client.DefaultRequestHeaders.Add("X-Host-Token",token);
        return client;
    }
    public Dictionary<string,object> Pull(HttpClient client,CancellationToken cancellation) {
        using(var response=client.GetAsync(baseUrl+"/agent-pull-config?wait=25",cancellation).GetAwaiter().GetResult()) {
            if(response.Headers.Date.HasValue)ObserveServerClock(response.Headers.Date.Value.ToString("r"));
            if(!response.IsSuccessStatusCode)throw new ApiError((int)response.StatusCode);
            return Json.Obj(Json.Parse(response.Content.ReadAsStringAsync().GetAwaiter().GetResult()));
        }
    }
    public Dictionary<string,object> Call(string route,string method,object body=null) {
        for(int attempt=0;attempt<3;attempt++) {
            if(Cancelled!=null&&Cancelled())throw new OperationCanceledException();
            int status=0;
            try {
                var r=(HttpWebRequest)WebRequest.Create(baseUrl+"/"+route);r.Method=method;r.Accept="application/json";r.AllowAutoRedirect=false;r.Timeout=timeout*1000;r.ReadWriteTimeout=timeout*1000;r.Proxy=WebRequest.DefaultWebProxy;
                if(id!=""){r.Headers["X-Host-Id"]=id;r.Headers["X-Host-Token"]=token;}
                if(body!=null){byte[] bytes=Encoding.UTF8.GetBytes(Json.Stringify(body));r.ContentType="application/json";r.ContentLength=bytes.Length;using(var s=r.GetRequestStream())s.Write(bytes,0,bytes.Length);}
                using(var res=(HttpWebResponse)r.GetResponse())using(var stream=res.GetResponseStream())using(var reader=new StreamReader(stream)) {
                    ObserveServerClock(res.Headers[HttpResponseHeader.Date]);
                    status=(int)res.StatusCode;if(status<200||status>=300)throw new ApiError(status);
                    var b=new char[4096];var content=new StringBuilder();int n;while((n=reader.Read(b,0,b.Length))>0){if(content.Length+n>1048576)throw new InvalidDataException("Resposta excede limite.");content.Append(b,0,n);}
                    return Json.Obj(Json.Parse(content.ToString()));
                }
            } catch(WebException e) {var response=e.Response as HttpWebResponse;if(response!=null){status=(int)response.StatusCode;response.Dispose();}}
            if(Cancelled!=null&&Cancelled())throw new OperationCanceledException();
            if((status!=0&&status!=429&&status<500)||attempt==2)throw new ApiError(status);
            Thread.Sleep((attempt+1)*1000);
        }
        throw new ApiError(0);
    }
}
// One owner, one outstanding request. Commands and collection timers never wait on this worker.
public sealed class LongPollWorker:IDisposable {
    readonly CancellationTokenSource cancellation=new CancellationTokenSource();readonly Task worker;
    public LongPollWorker(Func<CancellationToken,Dictionary<string,object>> pull,Action<Dictionary<string,object>> receive,Action<string> log) {
        worker=Task.Factory.StartNew(()=>Run(pull,receive,log),CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);
    }
    public static int RetrySeconds(int status,int failures) {return status==401?60:(int)Math.Min(60,5*Math.Pow(2,Math.Min(4,Math.Max(0,failures-1))));}
    void Run(Func<CancellationToken,Dictionary<string,object>> pull,Action<Dictionary<string,object>> receive,Action<string> log) {
        int failures=0;
        while(!cancellation.IsCancellationRequested) {
            int status=0;
            try {var response=pull(cancellation.Token);if(cancellation.IsCancellationRequested)break;receive(response);failures=0;continue;}
            catch(OperationCanceledException){if(cancellation.IsCancellationRequested)break;log("poll_timeout");}
            catch(ApiError e){status=e.Status;log("poll_http_"+status+"_"+ApiError.Kind(status));}
            catch{if(cancellation.IsCancellationRequested)break;log("poll_network_or_contract_error");}
            failures=Math.Min(5,failures+1);
            if(cancellation.Token.WaitHandle.WaitOne(RetrySeconds(status,failures)*1000))break;
        }
    }
    public void Dispose(){cancellation.Cancel();worker.GetAwaiter().GetResult();worker.Dispose();cancellation.Dispose();}
}
public sealed class Intervals {
    public readonly Dictionary<string,int> Values=new Dictionary<string,int>{{"metrics",3600},{"ips",3600},{"processes",3600},{"poll",60},{"heartbeat",300}};
    public void Apply(Dictionary<string,object>d) {
        var next=new Dictionary<string,int>(Values);
        foreach(string k in new List<string>(Values.Keys)) { int n=Json.Int(d,k,Values[k]);int min=k=="poll"?15:k=="heartbeat"?30:60;if(n<min||n>86400)throw new InvalidDataException("Intervalo inválido: "+k);next[k]=n; }
        foreach(var p in next)Values[p.Key]=p.Value;
    }
}
public sealed class CommandJournal {
    readonly Func<DateTime> utcNow;readonly string dir,host;readonly HashSet<string> pending=new HashSet<string>();readonly object pendingGate=new object();
    public CommandJournal(string root,string hostId,Func<DateTime> clock=null) {utcNow=clock??(()=>DateTime.UtcNow);dir=Path.Combine(root,"state","commands");Directory.CreateDirectory(dir);host=hostId;foreach(string path in Directory.EnumerateFiles(dir,"*.json")){var r=Recover(path);if(!Json.Bool(r,"acknowledged"))lock(pendingGate)pending.Add(Json.Str(r,"command_id"));}}
    public Dictionary<string,object> Execute(Dictionary<string,object>cmd,Func<Dictionary<string,object>,string>action) {
        Guid g;if(!Guid.TryParse(Json.Str(cmd,"id"),out g))throw new InvalidDataException("ID inválido.");
        if(Json.Str(cmd,"host_id")!=host)throw new InvalidDataException("Comando de outro host.");
        string id=g.ToString(),path=Path.Combine(dir,id+".json");
        if(File.Exists(path)){var existing=Recover(path);if(!Json.Bool(existing,"acknowledged"))lock(pendingGate)pending.Add(id);return existing;}
        var record=new Dictionary<string,object>{{"command_id",id},{"state","started"},{"result","error"},{"message",""},{"acknowledged",false},{"created_at",Disk.Now()}};
        Disk.Write(path,record);
        try {
            DateTime expiry;if(!DateTime.TryParse(Json.Str(cmd,"expires_at"),CultureInfo.InvariantCulture,DateTimeStyles.AdjustToUniversal|DateTimeStyles.AssumeUniversal,out expiry)||expiry<=utcNow())throw new MaintenanceFailure("Comando expirado ou prazo invalido; nenhuma acao executada.");
            record["message"]=action(cmd);record["result"]="ok";
        } catch(ScriptResultFailure e){record["message"]=e.Message;record["result"]="error";} catch(MaintenanceFailure e){record["message"]=e.Message;record["result"]="error";} catch(Exception e) {record["message"]="Operacao falhou ("+e.GetType().Name+"). Verifique catalogo, sessao e acesso local.";record["result"]="error";}
        int limit=ScriptExecution.IsTarget(Json.Str(cmd,"target_id"))?2000:500;
        if(Convert.ToString(record["message"]).Length>limit)record["message"]=Convert.ToString(record["message"]).Substring(0,limit);
        record["state"]="completed";record["completed_at"]=Disk.Now();Disk.Write(path,record);lock(pendingGate)pending.Add(id);return record;
    }
    Dictionary<string,object> Recover(string path) {
        var r=Disk.Read(path);if(Json.Str(r,"state")=="started") {r["state"]="completed";r["result"]="error";r["message"]="Resultado incerto após interrupção; comando não repetido.";Disk.Write(path,r);}return r;
    }
    List<string> PendingIds(){lock(pendingGate)return new List<string>(pending);}
    public IEnumerable<Dictionary<string,object>> Pending() {foreach(string id in PendingIds()){var r=Recover(Path.Combine(dir,id+".json"));if(!Json.Bool(r,"acknowledged"))yield return r;}}
    public void Ack(Dictionary<string,object>r){r["acknowledged"]=true;Disk.Write(Path.Combine(dir,Json.Str(r,"command_id")+".json"),r);lock(pendingGate)pending.Remove(Json.Str(r,"command_id"));}
}
}
