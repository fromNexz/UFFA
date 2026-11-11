using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Uffa.InfraMonitor {
internal static class NativeWindows {
    [StructLayout(LayoutKind.Sequential)] internal struct FileTime {public uint Low,High;public DateTime Utc(){return DateTime.FromFileTimeUtc(((long)High<<32)|Low);} }
    [StructLayout(LayoutKind.Sequential)] internal struct FileInfo {public uint Attributes;public FileTime Creation,Access,Write;public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;public long Length(){return ((long)SizeHigh<<32)|SizeLow;} }
    [StructLayout(LayoutKind.Sequential)] struct StorageQuery {public int Property,Type;public byte Extra;}
    [StructLayout(LayoutKind.Sequential)] struct TrimDescriptor {public uint Version,Size;public byte Enabled;}
    [StructLayout(LayoutKind.Sequential)] struct FileDisposition {public byte Delete;}
    [StructLayout(LayoutKind.Sequential)] struct SessionInfo {public int Id;public IntPtr Name;public int State;}
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartupInfo {public int cb;public string reserved,desktop,title;public int x,y,xsize,ysize,xchars,ychars,fill,flags;public short show,reserved2;public IntPtr reservedPtr,input,output,error;}
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {public IntPtr Process,Thread;public int Pid,Tid;}
    [StructLayout(LayoutKind.Sequential)] struct Luid {public uint Low;public int High;}
    [StructLayout(LayoutKind.Sequential)] struct TokenPrivileges {public uint Count;public Luid Id;public uint Attributes;}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] internal static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] internal static extern bool GetFileInformationByHandle(SafeFileHandle file,out FileInfo info);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandle(SafeFileHandle file,StringBuilder path,uint length,uint flags);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle file,int type,ref FileDisposition value,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool DeviceIoControl(SafeFileHandle device,uint code,ref StorageQuery query,uint inputSize,out TrimDescriptor output,uint outputSize,out uint returned,IntPtr overlapped);
    [DllImport("wtsapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool WTSEnumerateSessions(IntPtr server,int reserved,int version,out IntPtr info,out int count);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr memory);
    [DllImport("wtsapi32.dll",SetLastError=true)] static extern bool WTSQueryUserToken(int session,out SafeFileHandle token);
    [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out SafeFileHandle token);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string system,string name,out Luid id);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(SafeFileHandle token,bool disable,ref TokenPrivileges privileges,int length,IntPtr previous,IntPtr returned);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool DuplicateTokenEx(SafeFileHandle existing,uint access,IntPtr attributes,int level,int type,out SafeFileHandle duplicate);
    [DllImport("userenv.dll",SetLastError=true)] static extern bool CreateEnvironmentBlock(out IntPtr environment,SafeFileHandle token,bool inherit);
    [DllImport("userenv.dll")] static extern bool DestroyEnvironmentBlock(IntPtr environment);
    [DllImport("userenv.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserProfileDirectory(SafeFileHandle token,StringBuilder path,ref uint size);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessAsUser(SafeFileHandle token,string app,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr environment,string directory,ref StartupInfo startup,out ProcessInfo info);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
    static MaintenanceFailure Failure(string stage){return new MaintenanceFailure(stage+" (Win32="+Marshal.GetLastWin32Error()+").");}
    static void EnablePrivilege(string name) {
        SafeFileHandle token;if(!OpenProcessToken(GetCurrentProcess(),0x20|0x8,out token))throw Failure("Token do servico indisponivel");
        using(token){Luid luid;if(!LookupPrivilegeValue(null,name,out luid))throw Failure("Privilegio indisponivel");var p=new TokenPrivileges{Count=1,Id=luid,Attributes=2};if(!AdjustTokenPrivileges(token,false,ref p,0,IntPtr.Zero,IntPtr.Zero)||Marshal.GetLastWin32Error()!=0)throw Failure("Servico sem privilegio para iniciar aplicativo na sessao ativa");}
    }
    internal static string FinalPath(SafeFileHandle file) {
        var b=new StringBuilder(1024);uint n=GetFinalPathNameByHandle(file,b,(uint)b.Capacity,0);if(n==0)throw Failure("Caminho final indisponivel");if(n>=b.Capacity){b=new StringBuilder((int)n+1);n=GetFinalPathNameByHandle(file,b,(uint)b.Capacity,0);if(n==0||n>=b.Capacity)throw Failure("Caminho final invalido");}return MaintenancePolicy.NormalPath(b.ToString());
    }
    internal static bool TrimSupported() {
        using(var h=CreateFile(@"\\.\C:",0,3,IntPtr.Zero,3,0,IntPtr.Zero)){if(h.IsInvalid)return false;var q=new StorageQuery{Property=8,Type=0};TrimDescriptor d;uint n;return DeviceIoControl(h,0x002D1400,ref q,(uint)Marshal.SizeOf(typeof(StorageQuery)),out d,(uint)Marshal.SizeOf(typeof(TrimDescriptor)),out n,IntPtr.Zero)&&n>=9&&d.Enabled!=0;}
    }
    internal static SafeFileHandle OpenTempRoot(string root) {
        // No delete sharing: keep this directory fixed while cleaning its descendants.
        var h=CreateFile(root,0x80,0x1|0x2,IntPtr.Zero,3,0x02000000|0x00200000,IntPtr.Zero);
        FileInfo info;if(h.IsInvalid||!GetFileInformationByHandle(h,out info)||(info.Attributes&0x400)!=0||(info.Attributes&0x10)==0){h.Dispose();throw new MaintenanceFailure("Raiz temporaria inacessivel ou link; preservada.");}return h;
    }
    internal static long DeleteOldTempFile(string path,string physicalRoot,DateTime now) {
        using(var h=CreateFile(path,0x10000|0x80,0,IntPtr.Zero,3,0x00200000,IntPtr.Zero)){
            FileInfo i;if(h.IsInvalid||!GetFileInformationByHandle(h,out i))return -1;
            if((i.Creation.High==0&&i.Creation.Low==0)||(i.Write.High==0&&i.Write.Low==0))return -1;
            if((i.Attributes&(0x400|0x10|0x4|0x1))!=0||i.Links!=1||!MaintenancePolicy.BelowRoot(physicalRoot,FinalPath(h))||!MaintenancePolicy.ExpiredTemp(i.Creation.Utc(),i.Write.Utc(),now))return -1;
            var disposition=new FileDisposition{Delete=1};if(!SetFileInformationByHandle(h,4,ref disposition,1))return -1;return i.Length();
        }
    }
    internal sealed class UserSession:IDisposable {
        readonly SafeFileHandle token;readonly IntPtr environment;public readonly int SessionId;public readonly string Profile;
        internal UserSession() {
            var active=new List<int>();IntPtr ptr;int count;if(!WTSEnumerateSessions(IntPtr.Zero,0,1,out ptr,out count))throw Failure("Falha ao consultar sessoes Windows");
            try{int size=Marshal.SizeOf(typeof(SessionInfo));for(int x=0;x<count;x++){var row=(SessionInfo)Marshal.PtrToStructure(IntPtr.Add(ptr,x*size),typeof(SessionInfo));if(row.State==0&&row.Id>0)active.Add(row.Id);}}finally{WTSFreeMemory(ptr);}
            SessionId=MaintenancePolicy.ChooseSession(unchecked((int)WTSGetActiveConsoleSessionId()),active);
            EnablePrivilege("SeTcbPrivilege");EnablePrivilege("SeAssignPrimaryTokenPrivilege");EnablePrivilege("SeIncreaseQuotaPrivilege");
            SafeFileHandle source;if(!WTSQueryUserToken(SessionId,out source))throw Failure("Token do usuario ativo indisponivel; requer LocalSystem");
            using(source){if(!DuplicateTokenEx(source,0xF01FF,IntPtr.Zero,2,1,out token))throw Failure("Falha ao preparar token interativo");}
            try{
                if(!CreateEnvironmentBlock(out environment,token,false))throw Failure("Ambiente do usuario indisponivel");
                uint size=32768;var path=new StringBuilder((int)size);if(!GetUserProfileDirectory(token,path,ref size))throw Failure("Perfil do usuario indisponivel");Profile=path.ToString();
            }catch{if(environment!=IntPtr.Zero)DestroyEnvironmentBlock(environment);token.Dispose();throw;}
        }
        internal void VerifyExecutableAccess(string exe){using(WindowsIdentity.Impersonate(token.DangerousGetHandle()))using(var f=File.Open(exe,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)){} }
        internal int Start(string exe,bool tray=false) {
            VerifyExecutableAccess(exe);var startup=new StartupInfo{cb=Marshal.SizeOf(typeof(StartupInfo)),desktop=@"winsta0\default",flags=1,show=7};ProcessInfo info;
            if(!CreateProcessAsUser(token,exe,new StringBuilder("\""+exe+"\""+(tray?" --tray":"")),IntPtr.Zero,IntPtr.Zero,false,0x400|0x08000000,environment,Path.GetDirectoryName(exe),ref startup,out info))throw Failure("Falha ao iniciar aplicativo no usuario ativo");
            try{return info.Pid;}finally{if(info.Thread!=IntPtr.Zero)CloseHandle(info.Thread);if(info.Process!=IntPtr.Zero)CloseHandle(info.Process);}
        }
        internal void EmptyRecycleBin(Action checkCancelled){
            string helper=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"InfraMonitor.UserTask.exe");
            if(!File.Exists(helper))throw new MaintenanceFailure("Lixeira: helper local ausente; atualize o pacote completo.");
            VerifyExecutableAccess(helper);string sid;using(var identity=new WindowsIdentity(token.DangerousGetHandle())){if(identity.User==null)throw new MaintenanceFailure("Lixeira: SID do usuario ativo indisponivel.");sid=identity.User.Value;}
            var startup=new StartupInfo{cb=Marshal.SizeOf(typeof(StartupInfo)),desktop=@"winsta0\default",flags=1,show=0};ProcessInfo info;
            if(!CreateProcessAsUser(token,helper,new StringBuilder("\""+helper+"\" --empty-recycle-bin "+sid),IntPtr.Zero,IntPtr.Zero,false,0x400|0x08000000,environment,Path.GetDirectoryName(helper),ref startup,out info))throw Failure("Lixeira: falha ao iniciar helper na sessao ativa");
            bool finished=false;
            try{
                var timer=System.Diagnostics.Stopwatch.StartNew();
                while(true){checkCancelled();uint wait=WaitForSingleObject(info.Process,200);if(wait==0){finished=true;break;}if(wait==0xFFFFFFFF)throw Failure("Lixeira: falha ao aguardar helper");if(timer.Elapsed.TotalSeconds>60)throw new MaintenanceFailure("Lixeira: helper nao confirmou conclusao em 60s.");}
                uint code;if(!GetExitCodeProcess(info.Process,out code))throw Failure("Lixeira: resultado do helper indisponivel");if(code!=0)throw new MaintenanceFailure("Lixeira do usuario ativo nao concluida (HRESULT=0x"+code.ToString("X8")+").");
            }finally{if(!finished){TerminateProcess(info.Process,1);WaitForSingleObject(info.Process,5000);}if(info.Thread!=IntPtr.Zero)CloseHandle(info.Thread);if(info.Process!=IntPtr.Zero)CloseHandle(info.Process);}
        }
        public void Dispose(){if(environment!=IntPtr.Zero)DestroyEnvironmentBlock(environment);token.Dispose();}
    }
}
}
