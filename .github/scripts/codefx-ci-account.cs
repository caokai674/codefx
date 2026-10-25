// Narrow setup of a disposable CI account; never used by the product installer.
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class CodefxCiAccountV1 {
    [StructLayout(LayoutKind.Sequential)]
    struct Attributes {
        public uint Length;
        public IntPtr Root, Name;
        public uint Flags;
        public IntPtr Security, Qos;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct UnicodeString { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool LogonUserW(string user,string domain,string password,uint type,uint provider,out IntPtr token);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system,ref Attributes attrs,uint access,out IntPtr policy);
    [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr policy,IntPtr sid,ref UnicodeString rights,uint count);
    [DllImport("advapi32.dll")] static extern uint LsaRemoveAccountRights(IntPtr policy,IntPtr sid,bool all,ref UnicodeString rights,uint count);
    [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
    static void SetBatchRight(string sidText,bool remove) {
        var attrs=new Attributes(); attrs.Length=(uint)Marshal.SizeOf(typeof(Attributes));
        IntPtr policy;
        uint status=LsaOpenPolicy(IntPtr.Zero,ref attrs,0x810,out policy);
        if(status!=0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
        IntPtr sid=IntPtr.Zero, name=IntPtr.Zero;
        try {
            var identifier=new SecurityIdentifier(sidText);
            byte[] bytes=new byte[identifier.BinaryLength]; identifier.GetBinaryForm(bytes,0);
            sid=Marshal.AllocHGlobal(bytes.Length); Marshal.Copy(bytes,0,sid,bytes.Length);
            const string right="SeBatchLogonRight";
            name=Marshal.StringToHGlobalUni(right);
            var rights=new UnicodeString { Length=(ushort)(right.Length*2), MaximumLength=(ushort)(right.Length*2+2), Buffer=name };
            status=remove ? LsaRemoveAccountRights(policy,sid,false,ref rights,1) : LsaAddAccountRights(policy,sid,ref rights,1);
            if(status!=0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
        } finally {
            if(sid!=IntPtr.Zero) Marshal.FreeHGlobal(sid);
            if(name!=IntPtr.Zero) Marshal.FreeHGlobal(name);
            LsaClose(policy);
        }
    }
    static int Check(string user,string domain,string password) {
        IntPtr token;
        if(!LogonUserW(user,domain,password,4,0,out token)) return Marshal.GetLastWin32Error();
        CloseHandle(token); return 0;
    }
    public static bool EnsureBatchLogon(string user,string domain,string password,string sid) {
        int error=Check(user,domain,password);
        if(error==0) return false;
        if(error!=1385) throw new Win32Exception(error,"The disposable CI account cannot log on for a scheduled task (error " + error + ").");
        SetBatchRight(sid,false);
        error=Check(user,domain,password);
        if(error!=0) { SetBatchRight(sid,true); throw new Win32Exception(error,"Batch logon remains blocked by the runner policy (error " + error + ")."); }
        return true;
    }
    public static void RevokeBatchLogon(string sid) { SetBatchRight(sid,true); }
}
