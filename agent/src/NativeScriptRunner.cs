using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
namespace Uffa.InfraMonitor {
// Suspended launch + job assignment closes the child-creation race in Process.Start/AssignJobObject.
public static class NativeScriptRunner {
    [StructLayout(LayoutKind.Sequential)] struct Security {public int Length;public IntPtr Descriptor;public int Inherit;}
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Startup {public int Size;public string Reserved,Desktop,Title;public int X,Y,XSize,YSize,XCount,YCount,Fill,Flags;public short Show,ReservedSize;public IntPtr ReservedData,Input,Output,Error;}
    [StructLayout(LayoutKind.Sequential)] struct StartupEx {public Startup Startup;public IntPtr Attributes;}
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {public IntPtr Process,Thread;public int Pid,Tid;}
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {public long ProcessTime,JobTime;public uint Flags;public UIntPtr MinWorkingSet,MaxWorkingSet;public uint ActiveProcesses;public UIntPtr Affinity;public uint Priority,Scheduling;}
    [StructLayout(LayoutKind.Sequential)] struct IoCounters {public ulong ReadOperations,WriteOperations,OtherOperations,ReadBytes,WriteBytes,OtherBytes;}
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {public BasicLimits Basic;public IoCounters Io;public UIntPtr ProcessMemory,JobMemory,PeakProcessMemory,PeakJobMemory;}
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref Security security,int size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string name,uint access,uint share,ref Security security,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr security,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref ExtendedLimits limits,int length);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref StartupEx startup,out ProcessInfo info);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,int flags,ref IntPtr size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool PeekNamedPipe(IntPtr pipe,IntPtr buffer,uint length,IntPtr read,out uint available,IntPtr remaining);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadFile(IntPtr pipe,byte[] buffer,uint length,out uint read,IntPtr overlapped);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    static void Check(bool ok){if(!ok)throw new Win32Exception(Marshal.GetLastWin32Error());}
    static void Close(ref IntPtr h){if(h!=IntPtr.Zero&&h!=new IntPtr(-1))CloseHandle(h);h=IntPtr.Zero;}
    sealed class PipeDecoder {
        readonly Decoder decoder=Encoding.UTF8.GetDecoder();readonly byte[] bytes=new byte[4096];readonly char[] chars=new char[Encoding.UTF8.GetMaxCharCount(4096)];
        internal void Finish(ScriptOutput output){output.Append(chars,decoder.GetChars(new byte[0],0,0,chars,0,true));}
        internal void Pump(IntPtr pipe,ScriptOutput output){for(int n=0;n<16;n++){uint available;if(!PeekNamedPipe(pipe,IntPtr.Zero,0,IntPtr.Zero,out available,IntPtr.Zero)){int code=Marshal.GetLastWin32Error();if(code==109)return;throw new Win32Exception(code);}if(available==0)return;uint read;Check(ReadFile(pipe,bytes,Math.Min(available,(uint)bytes.Length),out read,IntPtr.Zero));if(read==0)return;output.Append(chars,decoder.GetChars(bytes,0,(int)read,chars,0,false));}}
    }
    public static ScriptExit Run(ScriptRequest request,Func<bool> cancelled){
        string dir=Path.GetFullPath(request.WorkingDirectory);if(!Path.IsPathRooted(request.WorkingDirectory)||!Directory.Exists(dir))throw new DirectoryNotFoundException("Diretorio de trabalho inexistente ou nao absoluto: "+request.WorkingDirectory);
        string system=Environment.GetFolderPath(Environment.SpecialFolder.System);if(Environment.Is64BitOperatingSystem&&!Environment.Is64BitProcess)system=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"Sysnative");string exe=Path.Combine(system,request.Target=="powershell"?@"WindowsPowerShell\v1.0\powershell.exe":"cmd.exe");if(!File.Exists(exe))throw new FileNotFoundException("Interpretador Windows nao encontrado.",exe);
        string command=ScriptRequest.Quote(exe)+" "+request.Arguments;if(command.Length>=32767)throw new InvalidDataException("Comando excede o limite de linha do Windows.");
        IntPtr stdout=IntPtr.Zero,stdoutWrite=IntPtr.Zero,stderr=IntPtr.Zero,stderrWrite=IntPtr.Zero,input=IntPtr.Zero,job=IntPtr.Zero,attributes=IntPtr.Zero,handles=IntPtr.Zero;ProcessInfo process=new ProcessInfo();bool initialized=false,assigned=false,success=false;
        try {
            var security=new Security{Length=Marshal.SizeOf(typeof(Security)),Inherit=1};Check(CreatePipe(out stdout,out stdoutWrite,ref security,0));Check(SetHandleInformation(stdout,1,0));Check(CreatePipe(out stderr,out stderrWrite,ref security,0));Check(SetHandleInformation(stderr,1,0));input=CreateFile("NUL",0x80000000,3,ref security,3,0,IntPtr.Zero);Check(input!=new IntPtr(-1));
            job=CreateJobObject(IntPtr.Zero,null);Check(job!=IntPtr.Zero);var limits=new ExtendedLimits();limits.Basic.Flags=0x2000;Check(SetInformationJobObject(job,9,ref limits,Marshal.SizeOf(typeof(ExtendedLimits))));
            IntPtr length=IntPtr.Zero;InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref length);if(length==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());attributes=Marshal.AllocHGlobal(length);Check(InitializeProcThreadAttributeList(attributes,1,0,ref length));initialized=true;
            handles=Marshal.AllocHGlobal(IntPtr.Size*3);Marshal.WriteIntPtr(handles,0,input);Marshal.WriteIntPtr(handles,IntPtr.Size,stdoutWrite);Marshal.WriteIntPtr(handles,IntPtr.Size*2,stderrWrite);Check(UpdateProcThreadAttribute(attributes,0,new IntPtr(0x20002),handles,new IntPtr(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero));
            var startup=new StartupEx{Startup=new Startup{Size=Marshal.SizeOf(typeof(StartupEx)),Flags=0x101,Input=input,Output=stdoutWrite,Error=stderrWrite},Attributes=attributes};
            if(cancelled())return new ScriptExit{Cancelled=true};Check(CreateProcess(exe,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,true,0x08080004,IntPtr.Zero,dir,ref startup,out process));Check(AssignProcessToJobObject(job,process.Process));assigned=true;Check(ResumeThread(process.Thread)!=0xFFFFFFFF);Close(ref stdoutWrite);Close(ref stderrWrite);Close(ref input);
            var output=new ScriptOutput();var outDecoder=new PipeDecoder();var errDecoder=new PipeDecoder();var timer=Stopwatch.StartNew();bool timeout=false,cancel=false;
            while(true){outDecoder.Pump(stdout,output);errDecoder.Pump(stderr,output);uint state=WaitForSingleObject(process.Process,10);if(state==0)break;if(state==0xFFFFFFFF)throw new Win32Exception(Marshal.GetLastWin32Error());cancel=cancelled();timeout=timer.Elapsed.TotalSeconds>=request.Timeout;if(cancel||timeout){Check(TerminateJobObject(job,1460));WaitForSingleObject(process.Process,5000);return new ScriptExit{TimedOut=timeout,Cancelled=cancel};}}
            outDecoder.Pump(stdout,output);errDecoder.Pump(stderr,output);outDecoder.Finish(output);errDecoder.Finish(output);uint exit;Check(GetExitCodeProcess(process.Process,out exit));
            // Normal completion may intentionally launch a background app. Only timeout/cancellation kills descendants.
            limits.Basic.Flags=0;Check(SetInformationJobObject(job,9,ref limits,Marshal.SizeOf(typeof(ExtendedLimits))));success=true;return new ScriptExit{Code=unchecked((int)exit),Output=output.Text};
        }finally{
            if(!success&&process.Process!=IntPtr.Zero){if(assigned)TerminateJobObject(job,1460);else TerminateProcess(process.Process,1460);WaitForSingleObject(process.Process,5000);}
            Close(ref process.Thread);Close(ref process.Process);Close(ref job);Close(ref stdout);Close(ref stdoutWrite);Close(ref stderr);Close(ref stderrWrite);Close(ref input);if(initialized)DeleteProcThreadAttributeList(attributes);if(attributes!=IntPtr.Zero)Marshal.FreeHGlobal(attributes);if(handles!=IntPtr.Zero)Marshal.FreeHGlobal(handles);
        }
    }
}
}
