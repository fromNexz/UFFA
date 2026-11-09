using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Uffa.InfraMonitor;
// Test doubles only: Windows collectors and service manager are NOT validated by this suite.
namespace Uffa.InfraMonitor {
 public static class WindowsMaintenance {public static string Operate(object[] c,Dictionary<string,object>command,Func<bool> stop,Func<DateTime>now,Func<bool>reliable){throw new PlatformNotSupportedException();}}
 public static class WindowsServiceHost {public static int Run(string[] a){throw new PlatformNotSupportedException();}}
 public static class WindowsPlatform {
  public static object Metrics(){throw new PlatformNotSupportedException();}
  public static object Probe(Dictionary<string,object>t,int timeout){throw new PlatformNotSupportedException();}
  public static Dictionary<string,object> Status(Dictionary<string,object>t){throw new PlatformNotSupportedException();}
  public static string Operate(object[] c,Dictionary<string,object>command){throw new PlatformNotSupportedException();}
 }
}
public static class AgentTests {
 static void Assert(bool b,string message){if(!b)throw new Exception(message);}
 static void Throws(Action a,string message){bool caught=false;try{a();}catch{caught=true;}Assert(caught,message);}
 static Dictionary<string,object> Command(string host){return new Dictionary<string,object>{{"id",Guid.NewGuid().ToString()},{"host_id",host},{"expires_at",DateTime.UtcNow.AddMinutes(10).ToString("o")},{"target_id","frcaixa"},{"operation","restart"}};}
 public static string[] Run(string dir){
  Directory.CreateDirectory(dir);var passed=new List<string>();Action<string,Action> test=(name,action)=>{action();passed.Add(name);};
  test("JSON roundtrip",()=>{var d=Json.Obj(Json.Parse(Json.Stringify(new {a="loja ç",b=new[]{1,2},c=true})));Assert(Json.Str(d,"a")=="loja ç"&&Json.Array(d,"b").Length==2&&Json.Bool(d,"c"),"JSON inválido");});
  test("HTTPS mandatory",()=>Throws(()=>new Api("http://example.com",new Dictionary<string,object>()),"Aceitou HTTP"));
  test("No credentials in URL",()=>Throws(()=>new Api("https://user:secret@example.com",new Dictionary<string,object>()),"Aceitou userinfo"));
  test("No query in base URL",()=>Throws(()=>new Api("https://example.com?token=x",new Dictionary<string,object>()),"Aceitou query"));
  test("HTTP 406 distinct diagnosis",()=>Assert(ApiError.Kind(406)=="contract_not_acceptable","406"));
  test("HTTP auth not transient",()=>Assert(ApiError.Kind(401)=="identity_rejected"&&ApiError.Kind(403)=="forbidden","Auth"));
  test("HTTP 500 and network transient",()=>Assert(ApiError.Kind(500)=="transient"&&ApiError.Kind(0)=="transient","Transient"));
  test("Independent intervals",()=>{var x=new Intervals();x.Apply(new Dictionary<string,object>{{"poll",30}});Assert(x.Values["poll"]==30&&x.Values["metrics"]==3600&&x.Values["heartbeat"]==300,"Intervals" );});
  test("Interval validation transactional",()=>{var x=new Intervals();Throws(()=>x.Apply(new Dictionary<string,object>{{"metrics",7200},{"ips",1}}),"Invalid accepted");Assert(x.Values["metrics"]==3600,"Partial mutation");});
  test("Atomic durable JSON replacement",()=>{string p=Path.Combine(dir,"replace.json");Disk.Write(p,new {n=1});Disk.Write(p,new {n=2});Assert(Json.Int(Disk.Read(p),"n",0)==2,"Replace");Assert(!Directory.EnumerateFiles(dir,"*.tmp").Any(),"Temporary files left");});
  string host=Guid.NewGuid().ToString();var journal=new CommandJournal(dir,host);
  test("Repeated command executes once",()=>{var c=Command(host);int count=0;var r=journal.Execute(c,x=>{count++;return "ok";});journal.Execute(c,x=>{count++;return "bad";});Assert(count==1&&Json.Str(r,"result")=="ok","Duplicated action");});
  test("Cross-host command rejected before action",()=>{var c=Command(Guid.NewGuid().ToString());int count=0;Throws(()=>journal.Execute(c,x=>{count++;return "bad";}),"Cross host");Assert(count==0,"Action executed");});
  test("Invalid command ID rejected",()=>{var c=Command(host);c["id"]="../../escape";Throws(()=>journal.Execute(c,x=>"bad"),"Traversal accepted");});
  test("Expired command never executes",()=>{var c=Command(host);c["expires_at"]=DateTime.UtcNow.AddMinutes(-1).ToString("o");int count=0;var r=journal.Execute(c,x=>{count++;return "bad";});Assert(count==0&&Json.Str(r,"result")=="error","Expired executed");});
  test("Missing expiry never executes",()=>{var c=Command(host);c.Remove("expires_at");int count=0;journal.Execute(c,x=>{count++;return "bad";});Assert(count==0,"Expiry ignored");});
  test("Action failure persisted and never replayed",()=>{var c=Command(host);int count=0;var r=journal.Execute(c,x=>{count++;throw new Exception("secret-do-not-log");});journal.Execute(c,x=>{count++;return "bad";});Assert(count==1&&Json.Str(r,"result")=="error"&&!Json.Str(r,"message").Contains("secret"),"Failure replay or secret exposed");});
  test("Crash intent recovered without replay",()=>{var c=Command(host);Disk.Write(Path.Combine(dir,"state","commands",Json.Str(c,"id")+".json"),new {command_id=c["id"],state="started",result="error",message="",acknowledged=false});int count=0;var r=journal.Execute(c,x=>{count++;return "bad";});Assert(count==0&&Json.Str(r,"result")=="error"&&Json.Str(r,"message").Contains("incerto"),"Crash replay");});
  test("Confirmation retries without reexecution",()=>{var c=Command(host);int count=0;var r=journal.Execute(c,x=>{count++;return "ok";});Assert(journal.Pending().Any(x=>Json.Str(x,"command_id")==Json.Str(c,"id")),"Missing pending");journal.Execute(c,x=>{count++;return "bad";});journal.Ack(r);Assert(count==1&&!journal.Pending().Any(x=>Json.Str(x,"command_id")==Json.Str(c,"id")),"Ack repeated effect");});
  test("Journal survives new process object",()=>{var c=Command(host);journal.Execute(c,x=>"ok");var other=new CommandJournal(dir,host);int count=0;other.Execute(c,x=>{count++;return "bad";});Assert(count==0,"Restart replay");});
  test("SHA256 matches standard vector",()=>Assert(Disk.Sha256("abc")=="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","Hash"));
  test("Logs rotate with bounded file count",()=>{var logger=new AgentLog(dir);for(int i=0;i<12;i++){File.WriteAllText(Path.Combine(dir,"logs","agent.log"),new string('x',1048577));logger.Event("test_event");}Assert(Directory.GetFiles(Path.Combine(dir,"logs")).Length==6,"Unbounded logs");});
  test("FrCaixa service cannot be controlled even with legacy permissions",()=>Throws(()=>CatalogPolicy.AssertControlAllowed(new Dictionary<string,object>{{"id","other"},{"service_name","FrCaixaMonitor"}}),"ERP control accepted"));
  test("Monitor executable cannot be controlled by path",()=>Throws(()=>CatalogPolicy.AssertControlAllowed(new Dictionary<string,object>{{"id","app"},{"executable",@"C:\FrCaixaMonitor\monitor.exe"}}),"Monitor control accepted"));
  test("Monitor executable protected outside usual directory",()=>Throws(()=>CatalogPolicy.AssertControlAllowed(new Dictionary<string,object>{{"id","app"},{"executable",@"D:\ERP\MONITOR.EXE"}}),"Alternate monitor control accepted"));
  test("Monitor observer works without executable path",()=>Assert(CatalogPolicy.IsMonitorObserver(new Dictionary<string,object>{{"kind","process"},{"process_name","monitor.exe"}}),"Observer missing"));
  test("Name-based observer cannot become command target",()=>Throws(()=>CatalogPolicy.AssertControlAllowed(new Dictionary<string,object>{{"id","app"},{"process_name","other.exe"}}),"Name observer control accepted"));
  test("Unrelated explicit target not blocked by ERP guard",()=>CatalogPolicy.AssertControlAllowed(new Dictionary<string,object>{{"id","test-service"},{"executable",@"C:\Test\app.exe"}}));

  Func<string,Dictionary<string,object>> target=id=>new Dictionary<string,object>{{"id",id},{"kind","process"},{"executable",id=="rustdesk"?MaintenancePolicy.RustDeskPath:@"C:\FrCaixaMonitor\monitor.exe"},{"remote_control_enabled",true},{"allowed_operations",new object[]{"start","stop","restart","kill"}},{"allow_force",true}};
  test("Remote FrCaixa explicitly authorized by local opt-in",()=>{var c=Command(host);var t=target("frcaixa");Assert(MaintenancePolicy.Authorize(new object[]{t},c)==t,"Opt in");});
  test("Legacy readonly FrCaixa remains protected",()=>{var c=Command(host);var t=target("frcaixa");t["remote_control_enabled"]=false;Throws(()=>MaintenancePolicy.Authorize(new object[]{t},c),"Readonly bypass");});
  test("Remote arbitrary executable is ignored",()=>{var c=Command(host);c["executable"]=@"C:\evil\cmd.exe";var t=target("frcaixa");Assert(Json.Str(MaintenancePolicy.Authorize(new object[]{t},c),"executable")==@"C:\FrCaixaMonitor\monitor.exe","Network executable used");});
  test("RustDesk fixed path enforced",()=>{var c=Command(host);c["target_id"]="rustdesk";var t=target("rustdesk");t["executable"]=@"C:\Other\rustdesk.exe";Throws(()=>MaintenancePolicy.Authorize(new object[]{t},c),"RustDesk path bypass");});
  test("RustDesk restart authorized locally",()=>{var c=Command(host);c["target_id"]="rustdesk";Assert(MaintenancePolicy.Authorize(new object[]{target("rustdesk")},c)!=null,"Rust restart");});
  test("Cleanup only start",()=>{var c=Command(host);c["target_id"]="system_cleanup";var t=target("system_cleanup");Throws(()=>MaintenancePolicy.Authorize(new object[]{t},c),"Cleanup restart");c["operation"]="start";Assert(MaintenancePolicy.Authorize(new object[]{t},c)!=null,"Cleanup start");});
  test("Force kill needs local allow_force",()=>{var c=Command(host);c["operation"]="kill";var t=target("frcaixa");t["allow_force"]=false;Throws(()=>MaintenancePolicy.Authorize(new object[]{t},c),"Kill bypass");});
  test("Unknown operation never authorized",()=>{var c=Command(host);c["operation"]="powershell";Throws(()=>MaintenancePolicy.Authorize(new object[]{target("frcaixa")},c),"Arbitrary operation");});
  test("Residual Fr processes scoped to configured directory",()=>{Assert(MaintenancePolicy.RelatedFrProcess(@"C:\FrCaixaMonitor\monitor.exe",@"C:\FrCaixaMonitor\monitorthread.exe","monitorthread.exe"),"Residual missing");Assert(!MaintenancePolicy.RelatedFrProcess(@"C:\FrCaixaMonitor\monitor.exe",@"C:\Windows\monitor.exe","monitor.exe"),"Outside directory allowed");Assert(!MaintenancePolicy.RelatedFrProcess(@"C:\FrCaixaMonitor\monitor.exe",@"C:\FrCaixaMonitor-other\monitor.exe","monitor.exe"),"Sibling allowed");});
  test("Local shell interpreter rejected",()=>Throws(()=>MaintenancePolicy.FullLocalExe(@"C:\Windows\System32\cmd.exe"),"Shell accepted"));
  test("Remote paths and traversal rejected",()=>{Throws(()=>MaintenancePolicy.FullLocalExe(@"\\server\app.exe"),"UNC");Throws(()=>MaintenancePolicy.FullLocalExe(@"C:\Apps\..\other.exe"),"Traversal");});
  test("24h cutoff keeps newly copied or recently written files",()=>{var now=DateTime.UtcNow;Assert(MaintenancePolicy.ExpiredTemp(now.AddDays(-2),now.AddDays(-2),now),"Old not eligible");Assert(!MaintenancePolicy.ExpiredTemp(now.AddHours(-1),now.AddDays(-2),now),"New copy eligible");Assert(!MaintenancePolicy.ExpiredTemp(now.AddDays(-2),now.AddHours(-1),now),"Recent write eligible");});
  test("Final file path cannot escape authorized temp root",()=>{Assert(MaintenancePolicy.BelowRoot(@"C:\Windows\Temp",@"\\?\C:\Windows\Temp\a.tmp"),"Normalized missing");Assert(!MaintenancePolicy.BelowRoot(@"C:\Windows\Temp",@"C:\Windows\Temp-other\file"),"Prefix escape");Assert(!MaintenancePolicy.BelowRoot(@"C:\Windows\Temp",@"C:\Windows\System32\config"),"Outside delete");});
  test("Interactive console session preferred over other active sessions",()=>Assert(MaintenancePolicy.ChooseSession(1,new List<int>{1,2})==1,"Console ignored"));
  test("No or ambiguous interactive session fails closed",()=>{Throws(()=>MaintenancePolicy.ChooseSession(-1,new List<int>()),"No session accepted");Throws(()=>MaintenancePolicy.ChooseSession(-1,new List<int>{2,3}),"Ambiguous accepted");Assert(MaintenancePolicy.ChooseSession(-1,new List<int>{2})==2,"Single RDP rejected");});
  test("Example command envelope binds to authenticated pull host",()=>{var c=Command(host);c.Remove("host_id");c.Remove("expires_at");var b=MaintenancePolicy.BindCommand(c,host);Assert(Json.Str(b,"host_id")==host&&Json.Str(b,"expires_at")!="","Binding missing");Assert(!c.ContainsKey("host_id"),"Original mutated");});
  test("Explicit cross-host command rejected before queue",()=>Throws(()=>MaintenancePolicy.BindCommand(Command(Guid.NewGuid().ToString()),host),"Host mismatch accepted"));
  test("Server time evaluates command expiry independently of bad local clock",()=>{var server=DateTime.UtcNow.AddHours(-3);var j=new CommandJournal(Path.Combine(dir,"serverclock"),host,()=>server);var c=Command(host);c["expires_at"]=server.AddMinutes(1).ToString("o");int n=0;Assert(Json.Str(j.Execute(c,x=>{n++;return "ok";}),"result")=="ok"&&n==1,"Used wrong clock");});
  test("Missing command expiry uses supplied trusted receive time",()=>{var c=Command(host);c.Remove("expires_at");DateTime now=DateTime.UtcNow.AddHours(-3);var bound=MaintenancePolicy.BindCommand(c,host,now);Assert(DateTime.Parse(Json.Str(bound,"expires_at")).ToUniversalTime()==now.AddMinutes(5),"Receive TTL clock");});
  test("Untrusted or shifted HTTPS clock blocks destructive cleanup policy",()=>{var a=new Api("https://example.com",new Dictionary<string,object>());Assert(!a.LocalClockReliable,"No reference accepted");a.ObserveServerClock(DateTime.UtcNow.ToString("r"));Assert(a.LocalClockReliable,"Current clock rejected");a.ObserveServerClock(DateTime.UtcNow.AddHours(-3).ToString("r"));Assert(!a.LocalClockReliable,"Bad clock accepted");});
  test("Operation errors limited to 500 characters",()=>{var j=new CommandJournal(Path.Combine(dir,"longresult"),host);var r=j.Execute(Command(host),x=>{throw new MaintenanceFailure(new string('x',800));});Assert(Json.Str(r,"result")=="error"&&Json.Str(r,"message").Length==500,"Message limit");});
  test("Worker does not block polling and deduplicates active command",()=>{
    var j=new CommandJournal(Path.Combine(dir,"worker"),host);var entered=new System.Threading.ManualResetEvent(false);var release=new System.Threading.ManualResetEvent(false);var sent=new System.Threading.ManualResetEvent(false);int calls=0;
    using(var w=new RemoteCommandWorker(j,host,c=>{System.Threading.Interlocked.Increment(ref calls);entered.Set();release.WaitOne(5000);return "done";},r=>{j.Ack(r);sent.Set();},code=>{})){
      try{var c=Command(host);Assert(w.Enqueue(c),"Not queued");Assert(entered.WaitOne(2000),"Not running");Assert(!w.Enqueue(c),"Duplicate active queued");Assert(!j.Pending().Any(),"Running action treated as crashed");Assert(calls==1,"Duplicate effect");release.Set();Assert(sent.WaitOne(2000),"No immediate completion");Assert(!j.Pending().Any(),"Ack missing");}finally{release.Set();}
    }entered.Dispose();release.Dispose();sent.Dispose();
  });
  test("Failed result delivery retries only confirmation",()=>{
    var j=new CommandJournal(Path.Combine(dir,"worker-retry"),host);var finished=new System.Threading.ManualResetEvent(false);int effects=0;
    using(var w=new RemoteCommandWorker(j,host,c=>{effects++;return "ok";},r=>{finished.Set();throw new IOException();},code=>{})){Assert(w.Enqueue(Command(host)),"Missing queue");Assert(finished.WaitOne(2000),"No attempt");}
    var pending=j.Pending().ToList();Assert(effects==1&&pending.Count==1,"Lost result or repeated effect");j.Ack(pending[0]);Assert(!j.Pending().Any(),"Retry ack");finished.Dispose();
  });

  return passed.ToArray();
 }
}
