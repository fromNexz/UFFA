using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
namespace Uffa.InfraMonitor {
public static class Program {
    public const string Version="2.0.1";
    static bool stop;
    public static int Main(string[] args) {
        if(Array.IndexOf(args,"--service")>=0)return WindowsServiceHost.Run(args);
        return ConsoleMain(args);
    }
    public static void RequestStop() { stop=true; }
    public static int ConsoleMain(string[] args) {
        string root=AppDomain.CurrentDomain.BaseDirectory;
        for(int i=0;i<args.Length;i++)if(args[i]=="--root"&&i+1<args.Length)root=Path.GetFullPath(args[++i]);
        if(Array.IndexOf(args,"--version")>=0){Console.WriteLine(Version);return 0;}
        using(var mutex=new Mutex(false,"Global\\UFFA-"+Disk.Sha256(root.ToLowerInvariant()).Substring(0,20))) {
            bool held=false;try {try{held=mutex.WaitOne(0);}catch(AbandonedMutexException){held=true;}if(!held)return 73;
                Console.CancelKeyPress+=(s,e)=>{e.Cancel=true;stop=true;};return Run(root);
            } catch {try{new AgentLog(root).Event("fatal_startup");}catch{}return 1;}finally{if(held)mutex.ReleaseMutex();}
        }
    }
    static int Run(string root) {
        var cfg=Disk.Read(Path.Combine(root,"config","agent.json"));if(Json.Int(cfg,"schema_version",0)!=2||Json.Array(cfg,"catalog").Length>64)throw new InvalidDataException("Configuração local inválida.");var identity=Disk.Read(Path.Combine(root,"config","identity.json"));Guid host;
        if(!Guid.TryParse(Json.Str(identity,"host_id"),out host)||Json.Str(identity,"token").Length<32)throw new InvalidDataException("Identidade inválida.");
        var log=new AgentLog(root);var api=new Api(Json.Str(cfg,"api_base_url"),identity,Json.Int(cfg,"http_timeout_seconds",15));
        api.Cancelled=()=>stop;
        var intervals=new Intervals();intervals.Apply(Json.Obj(cfg["intervals"]));
        var journal=new CommandJournal(root,host.ToString());object[] catalog=Json.Array(cfg,"catalog"),ips=new object[0];
        var clock=Stopwatch.StartNew();var next=new Dictionary<string,double>{{"poll",0},{"heartbeat",0},{"metrics",0},{"processes",0},{"ips",0},{"flush",0},{"memory",10}};
        Task worker=null;bool configured=false;int failures=0;
        var ipReadings=new Dictionary<string,object>();
        string lastIps=Path.Combine(root,"state","ip-readings.json");
        if(File.Exists(lastIps))try{foreach(var o in Json.Array(Disk.Read(lastIps),"ips")){var ip=Json.Obj(o);ipReadings[Json.Str(ip,"ip")]=ip;}}catch{log.Event("ip_cache_invalid");}
        string cache=Path.Combine(root,"state","config-cache.json");string configFingerprint="";
        if(File.Exists(cache))try{var saved=Disk.Read(cache);intervals.Apply(Json.Obj(saved["intervals"]));ips=Json.Array(saved,"ips");if(ips.Length<=128){configured=true;configFingerprint=Json.Stringify(new {intervals=saved["intervals"],ips=ips});}}catch{log.Event("config_cache_invalid");}
        log.Event("started_v"+Version);
        while(!stop) {
            double now=clock.Elapsed.TotalSeconds;
            if(now>=next["memory"]) {
                next["memory"]=now+10;using(var p=Process.GetCurrentProcess()) {
                    // Soft restart threshold, not an OS-enforced memory cap. Keep durable state before exit.
                    if(p.PrivateMemorySize64>80L*1024*1024||p.WorkingSet64>90L*1024*1024) {
                        GC.Collect();GC.WaitForPendingFinalizers();p.Refresh();
                        if(p.PrivateMemorySize64>80L*1024*1024||p.WorkingSet64>90L*1024*1024){log.Event("memory_soft_limit_restart");return 75;}
                    }
                }
            }
            if(now>=next["poll"]) {
                next["poll"]=now+intervals.Values["poll"];
                try {
                    var remote=api.Call("agent-pull-config","GET");
                    if(Json.Int(remote,"schema_version",0)!=2)throw new InvalidDataException("Backend v2 obrigatório.");
                    intervals.Apply(Json.Obj(remote["intervals"]));ips=Json.Array(remote,"ips");if(ips.Length>128)throw new InvalidDataException();
                    string fingerprint=Json.Stringify(new {intervals=remote["intervals"],ips=ips});if(configFingerprint!=fingerprint){next["ips"]=now;configFingerprint=fingerprint;Disk.Write(cache,new {intervals=remote["intervals"],ips=ips});}configured=true;failures=0;
                    foreach(object command in Json.Array(remote,"pending_commands")){if(stop)break;var result=journal.Execute(Json.Obj(command),c=>WindowsPlatform.Operate(catalog,c));next["processes"]=0;try{api.Call("agent-action-result","POST",new {command_id=result["command_id"],result=result["result"],message=result["message"]});journal.Ack(result);}catch(ApiError e){log.Event("result_"+"http_"+e.Status+"_"+ApiError.Kind(e.Status));}}
                } catch(ApiError e){log.Event("poll_"+"http_"+e.Status+"_"+ApiError.Kind(e.Status));failures++;} catch {log.Event("poll_contract_or_command_error");failures++;}
                if(failures>0)next["poll"]=now+Math.Min(900,intervals.Values["poll"]*Math.Pow(2,Math.Min(4,failures-1)));
            }
            if(stop)break;
            if(now>=next["flush"]) {
                next["flush"]=now+15;
                try {
                    foreach(var record in journal.Pending()) {
                        api.Call("agent-action-result","POST",new {command_id=record["command_id"],result=record["result"],message=record["message"]});journal.Ack(record);
                    }
                    if(worker==null||worker.IsCompleted) foreach(string type in new[]{"metrics","ips","processes"}) {
                        string path=Path.Combine(root,"state","outbox",type+".json");
                        if(File.Exists(path)){var body=Disk.Read(path);api.Call(type=="metrics"?"ingest":"agent-status","POST",body);
                            // Producer only starts after previous worker completes; compare IDs before removing snapshot.
                            if(File.Exists(path)&&Json.Str(Disk.Read(path),"observation_id")==Json.Str(body,"observation_id"))File.Delete(path);
                        }
                    }
                }catch(ApiError e){log.Event("outbox_"+"http_"+e.Status+"_"+ApiError.Kind(e.Status));}catch{log.Event("outbox_failed");}
            }
            if(stop)break;
            if(now>=next["heartbeat"]) {
                next["heartbeat"]=now+intervals.Values["heartbeat"];
                try {
                    using(var process=Process.GetCurrentProcess()) {
                        api.Call("agent-heartbeat","POST",new {schema_version=2,at=Disk.Now(),agent_version=Version,hostname=Environment.MachineName,working_set_bytes=process.WorkingSet64,private_bytes=process.PrivateMemorySize64,catalog=CatalogSummary(catalog)});
                    }
                    Disk.Write(Path.Combine(root,"state","health.json"),new {version=Version,last_success_at=Disk.Now()});
                }catch(ApiError e){log.Event("heartbeat_"+"http_"+e.Status+"_"+ApiError.Kind(e.Status));}catch{log.Event("heartbeat_failed");}
            }
            if(worker!=null&&worker.IsCompleted){if(worker.IsFaulted)log.Event("collection_failed");worker.Dispose();worker=null;GC.Collect(0);}
            if(configured&&worker==null) {
                string kind=null;foreach(string k in new[]{"metrics","processes","ips"})if(now>=next[k]){kind=k;break;}
                if(kind!=null) {
                    next[kind]=now+intervals.Values[kind];string selected=kind;object[] targets=ips;int ipDefault=intervals.Values["ips"];
                    if(selected=="ips"){int cadence=targets.Length==0?ipDefault:86400;foreach(object o in targets){int seconds=Json.Int(Json.Obj(o),"interval_seconds",ipDefault);if(seconds==0)seconds=ipDefault;cadence=Math.Min(cadence,Math.Max(60,seconds));}next["ips"]=now+cadence;}
                    worker=Task.Factory.StartNew(()=>{
                        object body;
                        if(selected=="metrics")body=new {schema_version=2,observation_id=Guid.NewGuid().ToString(),metrics=WindowsPlatform.Metrics()};
                        else if(selected=="ips") {
                            var results=new List<object>();var retained=new Dictionary<string,object>();
                            foreach(object o in targets){var target=Json.Obj(o);string key=Json.Str(target,"ip");int seconds=Json.Int(target,"interval_seconds",ipDefault);if(seconds==0)seconds=ipDefault;if(seconds<60||seconds>86400)throw new InvalidDataException("Intervalo de IP inválido.");object prior=null;bool due=true;
                                if(ipReadings.TryGetValue(key,out prior)){DateTime last;if(DateTime.TryParse(Json.Str(Json.Obj(prior),"checked_at"),out last))due=(DateTime.UtcNow-last.ToUniversalTime()).TotalSeconds>=seconds;}
                                object reading=due?Json.Parse(Json.Stringify(WindowsPlatform.Probe(target,Math.Max(250,Math.Min(3000,Json.Int(cfg,"probe_timeout_ms",1500)))))):prior;
                                results.Add(reading);retained[key]=reading;
                            }
                            ipReadings=retained;Disk.Write(lastIps,new {ips=results});body=new {schema_version=2,observation_id=Guid.NewGuid().ToString(),kind="ips",checked_at=Disk.Now(),ips=results};
                        }
                        else {var results=new List<object>();foreach(object t in catalog){try{results.Add(WindowsPlatform.Status(Json.Obj(t)));}catch{results.Add(new {target_id=Json.Str(Json.Obj(t),"id"),checked_at=Disk.Now(),is_running=(bool?)null,health="unknown",error="local_configuration_or_access_error"});}}body=new {schema_version=2,observation_id=Guid.NewGuid().ToString(),kind="processes",checked_at=Disk.Now(),targets=results};}
                        Disk.Write(Path.Combine(root,"state","outbox",selected+".json"),body);
                    });
                }
            }
            Thread.Sleep(250);
        }
        return 0;
    }
    static object CatalogSummary(object[] catalog) {
        var summary=new List<object>();foreach(object o in catalog){var t=Json.Obj(o);summary.Add(new {id=Json.Str(t,"id"),kind=Json.Str(t,"kind"),allowed_operations=Json.Array(t,"allowed_operations"),allow_force=Json.Bool(t,"allow_force")});}return summary;
    }
}
}
