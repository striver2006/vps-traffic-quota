namespace VpsQuota.Collectors;

using System.Diagnostics;
using System.Text;

public sealed record ProcessResult(int ExitCode, string Stdout, string Stderr);

/// <summary>
/// 可执行文件根本没能启动（找不到 ssh.exe、权限不足等）。
/// 单列一个类型，让调用方能可靠地区分它和"命令跑了但失败了"，
/// 而不是去匹配错误信息里的文字。
/// </summary>
public sealed class ProcessLaunchException : Exception
{
    public ProcessLaunchException(string message) : base(message) { }
}

public static class ProcessRunner
{
    /// <summary>
    /// 执行外部命令并等待结束。
    /// </summary>
    /// <param name="timeout">
    /// 硬超时。SSH 的 ConnectTimeout 只覆盖连接阶段，连上之后卡住
    /// （例如对端负载极高）仍可能无限等待，所以外面还要有一层。
    /// </param>
    public static async Task<ProcessResult> RunAsync(
        string fileName,
        IEnumerable<string> arguments,
        TimeSpan timeout,
        CancellationToken ct = default)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            // 明确切断标准输入：SSH 若因故想交互式提问（要密码、确认 host key），
            // 应当立刻失败并报错，而不是挂在那里等一个永远不会来的输入。
            RedirectStandardInput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);

        using var process = new Process { StartInfo = startInfo };

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        // 必须分别异步读 stdout 和 stderr：管道缓冲区填满后子进程会阻塞在 write 上，造成死锁。
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) stdout.AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) stderr.AppendLine(e.Data); };

        try
        {
            process.Start();
        }
        catch (Exception ex)
        {
            throw new ProcessLaunchException($"无法启动 {fileName}：{ex.Message}");
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        process.StandardInput.Close();

        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutSource.CancelAfter(timeout);

        try
        {
            await process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            TryKill(process);
            throw new CollectException($"命令执行超时（{(int)timeout.TotalSeconds} 秒）");
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            throw;
        }

        return new ProcessResult(process.ExitCode, stdout.ToString(), stderr.ToString());
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch
        {
            // 进程可能刚好自行退出，无需处理。
        }
    }
}
