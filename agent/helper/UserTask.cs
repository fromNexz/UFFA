using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
namespace Uffa.UserTask {
public static class RecyclePolicy {
    public const string Version="2.2.0";
    public static bool AlreadyEmpty(int queryResult,long items){return queryResult>=0&&items==0;}
    public static string Code(int value){return "0x"+unchecked((uint)value).ToString("X8");}
    public static bool ValidArguments(string[] args){return args.Length==2&&args[0]=="--empty-recycle-bin"&&System.Text.RegularExpressions.Regex.IsMatch(args[1],"^S-1-[0-9]+(?:-[0-9]+)+$");}
}
public static class EntryPoint {
    [StructLayout(LayoutKind.Sequential,Pack=1)] struct RecycleInfo {public uint Size;public long Bytes,Items;}
    [DllImport("shell32.dll",CharSet=CharSet.Unicode)] static extern int SHQueryRecycleBin(string root,ref RecycleInfo info);
    [DllImport("shell32.dll",CharSet=CharSet.Unicode)] static extern int SHEmptyRecycleBin(IntPtr owner,string root,uint flags);
    [DllImport("ole32.dll")] static extern int CoInitializeEx(IntPtr reserved,uint mode);
    [DllImport("ole32.dll")] static extern void CoUninitialize();
    public static int QueryStructureSize(){return Marshal.SizeOf(typeof(RecycleInfo));}
    const int Denied=unchecked((int)0x80070005),InvalidArgs=unchecked((int)0x80070057),Failed=unchecked((int)0x80004005);
    [STAThread]
    public static int Main(string[] args){
        if(args.Length==1&&args[0]=="--version"){Console.WriteLine(RecyclePolicy.Version);return 0;}
        if(!RecyclePolicy.ValidArguments(args))return InvalidArgs;
        try {
            string sid;using(var user=WindowsIdentity.GetCurrent()){if(user.User==null)return Denied;sid=user.User.Value;}
            if(!String.Equals(sid,args[1],StringComparison.Ordinal))return Denied;
            // Metadata only: missing own SID directory means no recycle bin has been created.
            string folder=Path.Combine(@"C:\$Recycle.Bin",sid);
            try{File.GetAttributes(folder);}catch(DirectoryNotFoundException){return 0;}catch(FileNotFoundException){return 0;}catch(UnauthorizedAccessException){return Denied;}
            int init=CoInitializeEx(IntPtr.Zero,2);if(init<0)return init;
            try{
                var before=new RecycleInfo{Size=(uint)Marshal.SizeOf(typeof(RecycleInfo))};int queried=SHQueryRecycleBin(@"C:\",ref before);
                if(RecyclePolicy.AlreadyEmpty(queried,before.Items))return 0;
                int result=SHEmptyRecycleBin(IntPtr.Zero,@"C:\",1|2|4);
                var after=new RecycleInfo{Size=(uint)Marshal.SizeOf(typeof(RecycleInfo))};int checkedResult=SHQueryRecycleBin(@"C:\",ref after);
                if(RecyclePolicy.AlreadyEmpty(checkedResult,after.Items))return 0;
                if(result<0)return result;if(checkedResult<0)return checkedResult;return Failed;
            }finally{CoUninitialize();}
        }catch(Exception){return Failed;}
    }
}
}
