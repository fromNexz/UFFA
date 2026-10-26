using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.ServiceProcess;
namespace Uffa.InfraMonitor {
public sealed class WindowsServiceHost:ServiceBase {
    readonly string[] args;System.Threading.Thread thread;
    WindowsServiceHost(string[] a){args=a;ServiceName="InfraMonitorAgent";CanStop=true;AutoLog=false;}
    public static int Run(string[] a){ServiceBase.Run(new WindowsServiceHost(a));return 0;}
    protected override void OnStart(string[] ignored){thread=new System.Threading.Thread(()=>{int code=Program.ConsoleMain(args);if(code!=0)Environment.Exit(code);});thread.IsBackground=true;thread.Start();}
    protected override void OnStop(){RequestAdditionalTime(60000);Program.RequestStop();if(thread!=null&&!thread.Join(55000))Environment.Exit(75);}
}
public static class WindowsPlatform {
    static List<Dictionary<string,object>> Query(string query,params string[] props) {
        var result=new List<Dictionary<string,object>>();
        using(var search=new ManagementObjectSearcher(query))using(var rows=search.Get())foreach(ManagementObject row in rows)using(row){var d=new Dictionary<string,object>();foreach(string p in props)d[p]=row[p];result.Add(d);}return result;
    }
    public static object Metrics() {
        var os=Query("SELECT TotalVisibleMemorySize,FreePhysicalMemory,LastBootUpTime FROM Win32_OperatingSystem","TotalVisibleMemorySize","FreePhysicalMemory","LastBootUpTime")[0];
        double total=Convert.ToDouble(os["TotalVisibleMemorySize"])*1024,free=Convert.ToDouble(os["FreePhysicalMemory"])*1024,cpu=0;int count=0;
        foreach(var c in Query("SELECT LoadPercentage FROM Win32_Processor","LoadPercentage")){cpu+=Convert.ToDouble(c["LoadPercentage"]);count++;}
        var disks=new List<object>();foreach(var d in Query("SELECT DeviceID,Size,FreeSpace FROM Win32_LogicalDisk WHERE DriveType=3","DeviceID","Size","FreeSpace"))disks.Add(new {name=d["DeviceID"],total_bytes=Convert.ToInt64(d["Size"]),free_bytes=Convert.ToInt64(d["FreeSpace"])});
        var ips=new List<string>();foreach(var nic in NetworkInterface.GetAllNetworkInterfaces())if(nic.OperationalStatus==OperationalStatus.Up&&nic.NetworkInterfaceType!=NetworkInterfaceType.Loopback)foreach(var ip in nic.GetIPProperties().UnicastAddresses)ips.Add(ip.Address.ToString());
        return new {collected_at=Disk.Now(),hostname=Environment.MachineName,agent_version=Program.Version,cpu_percent=count>0?cpu/count:0,memory=new {total_bytes=total,available_bytes=free,used_percent=Math.Round(100*(total-free)/total,2)},uptime_seconds=(long)(DateTime.Now-ManagementDateTimeConverter.ToDateTime(Convert.ToString(os["LastBootUpTime"]))).TotalSeconds,disks=disks,local_ips=ips,public_ip=(string)null};
    }
    public static bool Tcp(string ip,int port,int timeout) {
        using(var client=new TcpClient()) {IAsyncResult pending=null;try {pending=client.BeginConnect(IPAddress.Parse(ip),port,null,null);using(var handle=pending.AsyncWaitHandle){if(!handle.WaitOne(timeout))return false;client.EndConnect(pending);return true;}}catch{return false;}}
    }
    public static object Probe(Dictionary<string,object>target,int timeout) {
        IPAddress ip;if(!IPAddress.TryParse(Json.Str(target,"ip"),out ip))throw new InvalidDataException("IP inválido.");
        object[] ports=Json.Array(target,"tcp_ports");if(ports.Length>32)throw new InvalidDataException();bool up=true;
        if(ports.Length==0){using(var ping=new Ping())try{up=ping.Send(ip,timeout).Status==IPStatus.Success;}catch{up=false;}}
        else foreach(object p in ports){int port=Convert.ToInt32(p);if(port<1||port>65535)throw new InvalidDataException();if(!Tcp(ip.ToString(),port,timeout)){up=false;break;}}
        return new {ip=ip.ToString(),is_up=up,checked_at=Disk.Now(),protocol=ports.Length==0?"icmp":"tcp"};
    }
    static string Executable(Dictionary<string,object>t) {
        string path=Json.Str(t,"executable");if(path.Length<4||path[1]!=':'||path[2]!='\\'||path.Contains("\"")||path.Contains("\r")||path.Contains("\n"))throw new InvalidDataException("Caminho local absoluto obrigatório.");return Path.GetFullPath(path);
    }
    static Dictionary<string,object> Service(Dictionary<string,object>t) {
        string name=Json.Str(t,"service_name");if(!System.Text.RegularExpressions.Regex.IsMatch(name,"^[A-Za-z0-9_.-]{1,100}$"))throw new InvalidDataException("Nome de serviço inválido.");
        var rows=Query("SELECT Name,PathName,State,ProcessId FROM Win32_Service WHERE Name='"+name+"'","Name","PathName","State","ProcessId");
        if(rows.Count==0){string pattern=Json.Str(t,"display_name_pattern");if(pattern!=""){var matches=new List<ServiceController>();foreach(var s in ServiceController.GetServices())using(s){if(s.DisplayName.IndexOf(pattern,StringComparison.OrdinalIgnoreCase)>=0)matches.Add(new ServiceController(s.ServiceName));}try{if(matches.Count!=1)throw new InvalidDataException("Serviço ausente ou ambíguo.");rows=Query("SELECT Name,PathName,State,ProcessId FROM Win32_Service WHERE Name='"+matches[0].ServiceName.Replace("'","''")+"'","Name","PathName","State","ProcessId");}finally{foreach(var s in matches)s.Dispose();}}}
        if(rows.Count!=1)throw new InvalidDataException("Serviço ausente ou ambíguo.");
        string command=Json.Str(rows[0],"PathName").Trim(),exe;
        if(command.StartsWith("\"")){int close=command.IndexOf('"',1);if(close<0)throw new InvalidDataException();exe=command.Substring(1,close-1);}else{int space=command.IndexOf(' ');exe=space<0?command:command.Substring(0,space);}
        if(!String.Equals(Path.GetFullPath(exe),Executable(t),StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("Caminho do serviço diverge do catálogo.");return rows[0];
    }
    static List<Dictionary<string,object>> Processes(Dictionary<string,object>t) {
        string exe=Executable(t),name=Path.GetFileName(exe).Replace("'","''");var result=new List<Dictionary<string,object>>();
        foreach(var p in Query("SELECT ProcessId,ExecutablePath,CreationDate FROM Win32_Process WHERE Name='"+name+"'","ProcessId","ExecutablePath","CreationDate"))if(String.Equals(Convert.ToString(p["ExecutablePath"]),exe,StringComparison.OrdinalIgnoreCase))result.Add(p);return result;
    }
    public static Dictionary<string,object> Status(Dictionary<string,object>t) {
        string kind=Json.Str(t,"kind");if(kind!="service"&&kind!="process")throw new InvalidDataException("Tipo inválido.");var svc=kind=="service"?Service(t):null;var processes=Processes(t);bool running=svc!=null?Json.Str(svc,"State")=="Running":processes.Count>0;
        var details=new List<object>();foreach(var p in processes){DateTime start=ManagementDateTimeConverter.ToDateTime(Json.Str(p,"CreationDate"));details.Add(new {pid=Convert.ToInt32(p["ProcessId"]),executable=p["ExecutablePath"],started_at=start.ToUniversalTime().ToString("o"),uptime_seconds=(long)(DateTime.Now-start).TotalSeconds});}
        int port=Json.Int(t,"health_tcp_port",0);string health=!running?"down":port>0?(Tcp("127.0.0.1",port,1000)?"healthy":"unhealthy"):"unknown";
        return new Dictionary<string,object>{{"target_id",Json.Str(t,"id")},{"kind",kind},{"is_running",running},{"health",health},{"checked_at",Disk.Now()},{"service_name",svc==null?null:svc["Name"]},{"processes",details}};
    }
    public static string Operate(object[] catalog,Dictionary<string,object>command) {
        Dictionary<string,object>t=null;int matches=0;foreach(object o in catalog){var entry=Json.Obj(o);if(Json.Str(entry,"id")==Json.Str(command,"target_id")){t=entry;matches++;}}
        if(matches!=1)throw new InvalidDataException("Alvo não autorizado.");string op=Json.Str(command,"operation");bool allowed=false;foreach(object o in Json.Array(t,"allowed_operations"))if(Convert.ToString(o)==op)allowed=true;
        if(!allowed||(op!="start"&&op!="stop"&&op!="restart"&&op!="kill")||(op=="kill"&&!Json.Bool(t,"allow_force")))throw new InvalidDataException("Operação não autorizada.");
        string exe=Executable(t);if(!File.Exists(exe))throw new FileNotFoundException();
        if(Json.Str(t,"kind")=="service"&&op!="kill") {
            var svc=Service(t);using(var s=new ServiceController(Json.Str(svc,"Name"))) {
                if((op=="stop"||op=="restart")&&s.Status!=ServiceControllerStatus.Stopped){s.Stop();s.WaitForStatus(ServiceControllerStatus.Stopped,TimeSpan.FromSeconds(25));}
                s.Refresh();if((op=="start"||op=="restart")&&s.Status!=ServiceControllerStatus.Running){s.Start();s.WaitForStatus(ServiceControllerStatus.Running,TimeSpan.FromSeconds(25));}
            }
        } else {
            if(Json.Str(t,"kind")=="service")Service(t);
            if(op=="stop"||op=="restart"||op=="kill")foreach(var p in Processes(t))using(var live=Process.GetProcessById(Convert.ToInt32(p["ProcessId"]))) {
                // Pin a process handle, then use WMI for path validation: x86 MainModule cannot inspect x64 targets.
                if(live.Handle==IntPtr.Zero)throw new InvalidDataException("Processo indisponível.");
                var current=Query("SELECT ExecutablePath FROM Win32_Process WHERE ProcessId="+Convert.ToInt32(p["ProcessId"]),"ExecutablePath");
                if(current.Count!=1||!String.Equals(Json.Str(current[0],"ExecutablePath"),exe,StringComparison.OrdinalIgnoreCase)||Math.Abs((live.StartTime-ManagementDateTimeConverter.ToDateTime(Json.Str(p,"CreationDate"))).TotalSeconds)>1)throw new InvalidDataException("PID mudou.");
                if(op=="kill"){live.Kill();if(!live.WaitForExit(15000))throw new System.TimeoutException();}
                else if(!live.CloseMainWindow()||!live.WaitForExit(15000))throw new InvalidOperationException("Encerramento normal indisponível; configure serviço Windows.");
            }
            if((op=="start"||op=="restart")&&Processes(t).Count==0)using(var p=Process.Start(new ProcessStartInfo(exe){UseShellExecute=false,WorkingDirectory=Path.GetDirectoryName(exe)})){}
        }
        System.Threading.Thread.Sleep(2000);var state=Status(t);bool expected=op=="start"||op=="restart";
        if(Json.Bool(state,"is_running")!=expected||(expected&&Json.Str(state,"health")=="unhealthy"))throw new InvalidOperationException("Estado final não confirmado.");
        return "Operação "+op+" confirmada em "+Json.Str(t,"id")+"; saúde="+Json.Str(state,"health");
    }
}
}
