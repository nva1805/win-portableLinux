param([Parameter(Mandatory=$true)][string]$SourceDirectory, [Parameter(Mandatory=$true)][string]$OutputFile)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutputFile) { throw 'Seed ISO already exists. Choose a new output filename.' }
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class PortableLinuxIsoWriter {
    public static void Save(object image, string path) {
        IStream input = (IStream)image;
        IntPtr count = Marshal.AllocHGlobal(4);
        try {
            input.Seek(0, 0, IntPtr.Zero);
            byte[] buffer = new byte[1024 * 1024];
            using (FileStream output = new FileStream(path, FileMode.CreateNew, FileAccess.Write)) {
                while (true) {
                    input.Read(buffer, buffer.Length, count);
                    int read = Marshal.ReadInt32(count);
                    if (read == 0) break;
                    output.Write(buffer, 0, read);
                }
                output.Flush();
            }
        } finally { Marshal.FreeHGlobal(count); }
    }
}
'@
$image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$image.FileSystemsToCreate = 3
$image.VolumeName = 'cidata'
$image.Root.AddTree((Resolve-Path -LiteralPath $SourceDirectory).Path, $false)
$result = $image.CreateResultImage()
[PortableLinuxIsoWriter]::Save($result.ImageStream, $OutputFile)
Get-Item -LiteralPath $OutputFile | Select-Object FullName,Length
