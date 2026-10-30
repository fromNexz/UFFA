using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Uffa.InfraMonitor;
// Test doubles only: Windows collectors and service manager are NOT validated by this suite.
namespace Uffa.InfraMonitor {
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
  return passed.ToArray();
 }
}
