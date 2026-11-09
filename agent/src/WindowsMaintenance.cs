using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Management;
using System.ServiceProcess;
using System.Threading;
namespace Uffa.InfraMonitor {
public static class WindowsMaintenance {
    sealed class Deadline {
        readonly Stopwatch clock=Stopwatch.StartNew();readonly Func<bool> cancelled;
        internal Deadline(Func<bool>stop){cancelled=stop;}
        internal void Check(){if(cancelled()||clock.Elapsed.TotalSeconds>300)throw new MaintenanceFailure("Acao interrompida por parada do agente ou limite de 5 minutos.");}
        internal void Wait(int milliseconds){for(int n=0;n<milliseconds;n+=100){Check();Thread.Sleep(Math.Min(100,milliseconds-n));}}
    }
    sealed class AppProcess {internal int Id,Session;internal string Path,Name,Created;}
    public static string Operate(object[] catalog,Dictionary<string,object>command,Func<bool>cancelled,Func<DateTime>trustedUtc,Func<bool>clockReliable) {
        var t=MaintenancePolicy.Authorize(catalog,command);var deadline=new Deadline(cancelled);deadline.Check();string id=Json.Str(t,"id");
        if(id=="system_cleanup"){if(!clockReliable())throw new MaintenanceFailure("Limpeza bloqueada: relogio local diverge do servidor ou sem referencia HTTPS de hora; corrija antes de apagar temporarios.");return Cleanup(deadline,trustedUtc);}
        return ProcessAction(t,Json.Str(command,"operation"),deadline,id=="rustdesk");
    }
    static List<Dictionary<string,object>> Query(string query,params string[] fields) {return WindowsPlatform.Query(query,fields);}
    static List<AppProcess> Processes(string exe,bool frRelated) {
        string name=Path.GetFileName(exe).Replace("'","''");string where=frRelated?"Name='frcaixa.exe' OR Name='monitor.exe' OR Name='monitorthread.exe' OR Name='"+name+"'":"Name='RustDesk.exe'";
        var rows=Query("SELECT Name,ProcessId,ExecutablePath,CreationDate,SessionId FROM Win32_Process WHERE "+where,"Name","ProcessId","ExecutablePath","CreationDate","SessionId");var output=new List<AppProcess>();
        foreach(var r in rows){string path=Json.Str(r,"ExecutablePath"),n=Json.Str(r,"Name");if(path=="")throw new MaintenanceFailure("Processo encontrado sem caminho legivel; encerramento recusado por seguranca.");
            if(frRelated?!MaintenancePolicy.RelatedFrProcess(exe,path,n):!path.Equals(exe,StringComparison.OrdinalIgnoreCase))continue;
            if(Json.Str(r,"CreationDate")=="")throw new MaintenanceFailure("Processo sem horario de criacao legivel; encerramento recusado.");
            output.Add(new AppProcess{Id=Json.Int(r,"ProcessId",0),Session=Json.Int(r,"SessionId",0),Path=path,Name=n,Created=Json.Str(r,"CreationDate")});
        }return output;
    }
    static string ServiceExe(string line) {
        line=line.Trim();if(line.StartsWith("\"")){int end=line.IndexOf('"',1);return end>1?line.Substring(1,end-1):"";}
        int endExe=line.IndexOf(".exe",StringComparison.OrdinalIgnoreCase);if(endExe<0)return "";string exe=line.Substring(0,endExe+4);
        if(exe.Contains(" "))throw new MaintenanceFailure("Servico possui caminho com espacos sem aspas; reinicio automatico recusado.");return exe;
    }
    static List<string> Services(string exe) {
        var found=new List<string>();foreach(var r in Query("SELECT Name,PathName FROM Win32_Service","Name","PathName")){
            string line=Json.Str(r,"PathName");
            // Only inspect quoting of services that mention the authorized executable.
            if(line.IndexOf(exe,StringComparison.OrdinalIgnoreCase)<0)continue;
            if(ServiceExe(line).Equals(exe,StringComparison.OrdinalIgnoreCase))found.Add(Json.Str(r,"Name"));
        }if(found.Count>1)throw new MaintenanceFailure("Mais de um servico corresponde ao executavel; escolha local univoca necessaria.");return found;
    }
    static void StopService(string name,Deadline time){using(var s=new ServiceController(name)){s.Refresh();if(s.Status==ServiceControllerStatus.Stopped)return;s.Stop();var until=Stopwatch.StartNew();while(until.Elapsed.TotalSeconds<25){time.Check();s.Refresh();if(s.Status==ServiceControllerStatus.Stopped)return;time.Wait(200);}throw new MaintenanceFailure("Servico nao confirmou parada em 25 segundos.");}}
    static void StartService(string name,Deadline time){using(var s=new ServiceController(name)){s.Refresh();if(s.Status==ServiceControllerStatus.Running)return;s.Start();var until=Stopwatch.StartNew();while(until.Elapsed.TotalSeconds<25){time.Check();s.Refresh();if(s.Status==ServiceControllerStatus.Running)return;time.Wait(200);}throw new MaintenanceFailure("Servico nao confirmou inicializacao em 25 segundos.");}}
    static void StopOne(AppProcess expected,bool force,Deadline time,bool immediately) {
        Process p;try{p=Process.GetProcessById(expected.Id);}catch(ArgumentException){return;}
        using(p){if(p.Handle==IntPtr.Zero)throw new MaintenanceFailure("Processo indisponivel para validar identidade.");
            var current=Query("SELECT ExecutablePath,CreationDate FROM Win32_Process WHERE ProcessId="+expected.Id,"ExecutablePath","CreationDate");if(current.Count==0)return;
            if(!Json.Str(current[0],"ExecutablePath").Equals(expected.Path,StringComparison.OrdinalIgnoreCase)||Json.Str(current[0],"CreationDate")!=expected.Created||Math.Abs((p.StartTime.ToUniversalTime()-ManagementDateTimeConverter.ToDateTime(expected.Created).ToUniversalTime()).TotalSeconds)>1)throw new MaintenanceFailure("PID mudou; processo preservado.");
            if(p.HasExited)return;
            time.Check();if(!immediately){bool close=p.CloseMainWindow();if(close){var wait=Stopwatch.StartNew();while(wait.Elapsed.TotalSeconds<2){time.Check();if(p.WaitForExit(100))return;}}}
            if(!force)throw new MaintenanceFailure("Aplicativo nao encerrou normalmente; forca nao autorizada.");
            if(p.HasExited)return;try{p.Kill();}catch(InvalidOperationException){if(p.HasExited)return;throw;}var timer=Stopwatch.StartNew();while(timer.Elapsed.TotalSeconds<8){time.Check();if(p.WaitForExit(100))return;}throw new MaintenanceFailure("Processo nao confirmou encerramento.");
        }
    }
    static string ProcessAction(Dictionary<string,object>target,string operation,Deadline time,bool rust) {
        string exe=rust?MaintenancePolicy.RustDeskPath:MaintenancePolicy.FullLocalExe(Json.Str(target,"executable"));
        if(!File.Exists(exe))throw new MaintenanceFailure(rust?"Executavel RustDesk nao encontrado em C:\\Program Files\\RustDesk\\RustDesk.exe":"Executavel FrCaixa nao encontrado no caminho local configurado.");
        var before=Processes(exe,!rust);var services=Services(exe);var oldIds=new HashSet<int>();foreach(var p in before)oldIds.Add(p.Id);
        bool start=operation=="start"||operation=="restart",stop=operation=="stop"||operation=="restart"||operation=="kill";
        NativeWindows.UserSession session=null;
        try{
            // RustDesk must have a GUI in the active user's desktop. FrCaixa uses SCM only for an exact service match.
            if(start&&(rust||services.Count==0)){session=new NativeWindows.UserSession();session.VerifyExecutableAccess(exe);}
            if(operation=="start"){
                foreach(var p in before)if(p.Path.Equals(exe,StringComparison.OrdinalIgnoreCase)&&(session==null||p.Session==session.SessionId))return (rust?"RustDesk":"FrCaixa")+" ja ativo. PID: "+p.Id;
            }
            if(stop){foreach(string svc in services)StopService(svc,time);foreach(var p in Processes(exe,!rust))StopOne(p,Json.Bool(target,"allow_force"),time,operation=="kill");}
            if(!start){if(Processes(exe,!rust).Count>0)throw new MaintenanceFailure("Ainda existem processos autorizados ativos apos encerramento.");return (rust?"RustDesk":"FrCaixa")+" encerrado; estado confirmado.";}
            if(rust&&operation=="restart")time.Wait(2000);
            foreach(string svc in services)StartService(svc,time);
            if(session!=null)session.Start(exe,rust);
            var verify=Stopwatch.StartNew();while(verify.Elapsed.TotalSeconds<8){time.Check();foreach(var p in Processes(exe,!rust))if(p.Path.Equals(exe,StringComparison.OrdinalIgnoreCase)&&(operation!="restart"||!oldIds.Contains(p.Id))&&(session==null||p.Session==session.SessionId))return (rust?"RustDesk":"FrCaixa")+" "+(operation=="restart"?"reiniciado":"iniciado")+" com sucesso. Novo PID: "+p.Id+"; sessao "+p.Session+"; validacao "+verify.Elapsed.TotalSeconds.ToString("0.0",CultureInfo.InvariantCulture)+"s";time.Wait(200);}
            throw new MaintenanceFailure("Falha ao validar inicializacao do "+(rust?"RustDesk":"FrCaixa")+" apos 8 segundos.");
        }catch(MaintenanceFailure){throw;}catch(Exception e){throw new MaintenanceFailure("Acao "+operation+" falhou ("+e.GetType().Name+"). Verifique servico, sessao ativa e permissoes locais.");}
        finally{if(session!=null)session.Dispose();}
    }
    static string Cleanup(Deadline time,Func<DateTime>trustedUtc) {
        var os=Query("SELECT ProductType,Version FROM Win32_OperatingSystem","ProductType","Version")[0];
        if(Json.Int(os,"ProductType",0)!=1||!Json.Str(os,"Version").StartsWith("10.",StringComparison.Ordinal))throw new MaintenanceFailure("Limpeza automatica requer Windows 10/11; servidor nao foi alterado.");
        long before=new DriveInfo(@"C:\").AvailableFreeSpace,deleted=0;int skipped=0,files=0,seen=0;bool bounded=false;var warnings=new List<string>();NativeWindows.UserSession user=null;
        try{
            try{user=new NativeWindows.UserSession();}catch(MaintenanceFailure e){warnings.Add("sessao indisponivel: "+e.Message);}
            var roots=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            roots.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"Temp"));
            string agentTemp=Path.GetFullPath(Path.GetTempPath()).TrimEnd('\\');
            // LocalSystem TEMP may be Windows\Temp or its profile's AppData\Local\Temp, never an arbitrary drive root.
            if(agentTemp.EndsWith(@"\AppData\Local\Temp",StringComparison.OrdinalIgnoreCase)||agentTemp.Equals(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"Temp"),StringComparison.OrdinalIgnoreCase))roots.Add(agentTemp);
            if(user!=null)roots.Add(Path.Combine(user.Profile,@"AppData\Local\Temp"));
            DateTime now=trustedUtc();var scanTime=Stopwatch.StartNew();
            foreach(string root in roots){time.Check();if(!Directory.Exists(root))continue;
                try{using(var rootHandle=NativeWindows.OpenTempRoot(root)){
                    string physical=NativeWindows.FinalPath(rootHandle);if(!physical.Equals(MaintenancePolicy.NormalPath(Path.GetFullPath(root)),StringComparison.OrdinalIgnoreCase)){warnings.Add("TEMP com redirecionamento preservado");continue;}
                    var stack=new Stack<string>();stack.Push(root);
                    while(stack.Count>0){time.Check();if(seen>=20000||scanTime.Elapsed.TotalSeconds>100){bounded=true;break;}
                        string directory=stack.Pop();try{foreach(string path in Directory.EnumerateFileSystemEntries(directory)){time.Check();seen++;if(seen>20000){bounded=true;break;}
                            try{var attr=File.GetAttributes(path);if((attr&FileAttributes.ReparsePoint)!=0){skipped++;continue;}if((attr&FileAttributes.Directory)!=0){if(stack.Count<512)stack.Push(path);else bounded=true;continue;}
                                long bytes=NativeWindows.DeleteOldTempFile(path,physical,now);if(bytes>=0){deleted+=bytes;files++;}else skipped++;
                            }catch(IOException){skipped++;}catch(UnauthorizedAccessException){skipped++;}
                        }}catch(IOException){skipped++;}catch(UnauthorizedAccessException){skipped++;}
                    }
                }}catch(MaintenanceFailure){warnings.Add("TEMP inacessivel ou link preservado");}
            }
            if(bounded)warnings.Add("varredura limitada a 20 mil entradas/100s");
            time.Check();if(user!=null){try{user.EmptyRecycleBin();}catch(MaintenanceFailure){warnings.Add("lixeira nao concluida");}}
            time.Check();bool trim=RunTrim(time);if(!trim)warnings.Add("TRIM nao confirmado/nao suportado");
            double mb=Math.Max(0,(new DriveInfo(@"C:\").AvailableFreeSpace-before)/1048576.0);
            string result="Limpeza: "+files+" temporarios antigos removidos ("+(deleted/1048576.0).ToString("0.00",CultureInfo.InvariantCulture)+" MB); "+skipped+" itens preservados. C: "+mb.ToString("0.00",CultureInfo.InvariantCulture)+" MB livres adicionais (estimativa). TRIM "+(trim?"concluido":"nao confirmado")+".";
            if(warnings.Count>0)throw new MaintenanceFailure(result+" Parcial: "+String.Join("; ",warnings)+".");return result;
        }finally{if(user!=null)user.Dispose();}
    }
    static bool RunTrim(Deadline time) {
        if(!NativeWindows.TrimSupported())return false;
        string windows=Environment.GetFolderPath(Environment.SpecialFolder.Windows);string tool=Path.Combine(windows,Environment.Is64BitOperatingSystem&&!Environment.Is64BitProcess?@"Sysnative\defrag.exe":@"System32\defrag.exe");
        if(!File.Exists(tool))return false;
        using(var p=new Process()){
            p.StartInfo=new ProcessStartInfo(tool,"C: /L /U /V"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};p.OutputDataReceived+=(s,e)=>{};p.ErrorDataReceived+=(s,e)=>{};
            p.Start();try{p.PriorityClass=ProcessPriorityClass.BelowNormal;}catch(InvalidOperationException){}catch(System.ComponentModel.Win32Exception){}p.BeginOutputReadLine();p.BeginErrorReadLine();var wait=Stopwatch.StartNew();
            try{while(!p.WaitForExit(200)){time.Check();if(wait.Elapsed.TotalSeconds>150){p.Kill();p.WaitForExit(5000);return false;}}p.WaitForExit();return p.ExitCode==0;}
            catch{if(!p.HasExited){p.Kill();p.WaitForExit(5000);}throw;}
        }
    }
}
}
