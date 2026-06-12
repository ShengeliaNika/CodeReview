<#
.SYNOPSIS
    Watches review-queue.txt and performs automated code reviews.
#>

. "$PSScriptRoot\config.ps1"

$queueFile = "$PSScriptRoot\review-queue.txt"
$doneFile = "$PSScriptRoot\review-done.txt"

Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  Code Review Watcher" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Watching: $queueFile" -ForegroundColor Gray
Write-Host "Press Ctrl+C to stop" -ForegroundColor Gray
Write-Host ""

function Parse-MRUrl {
    param([string]$url)
    
    if ($url -match "https?://([^/]+)/(.+)/-/merge_requests/(\d+)") {
        return @{
            Host = $Matches[1]
            ProjectPath = $Matches[2]
            MrIid = $Matches[3]
            ProjectEncoded = [uri]::EscapeDataString($Matches[2])
        }
    }
    return $null
}

function Get-MRDetails {
    param($parsed)
    
    $headers = @{ "PRIVATE-TOKEN" = $GitLabToken }
    $baseUrl = "https://$($parsed.Host)/api/v4"
    
    $mrUrl = "$baseUrl/projects/$($parsed.ProjectEncoded)/merge_requests/$($parsed.MrIid)"
    $mr = Invoke-RestMethod -Uri $mrUrl -Headers $headers
    
    $changesUrl = "$mrUrl/changes"
    $changes = Invoke-RestMethod -Uri $changesUrl -Headers $headers
    
    return @{
        MR = $mr
        Changes = $changes.changes
        BaseUrl = $baseUrl
        ProjectEncoded = $parsed.ProjectEncoded
        MrIid = $parsed.MrIid
    }
}

function Review-CodeChanges {
    param($changes, $mr)
    
    $issues = @()
    
    foreach ($change in $changes) {
        $file = $change.new_path
        $diff = $change.diff
        
        if (-not $diff) { continue }
        
        $lines = $diff -split "`n"
        $currentLine = 0
        
        foreach ($line in $lines) {
            # Track line numbers from @@ markers
            if ($line -match "^@@.*\+(\d+)") {
                $currentLine = [int]$Matches[1] - 1
                continue
            }
            
            # Only check added lines
            if ($line.StartsWith("+") -and -not $line.StartsWith("+++")) {
                $currentLine++
                $code = $line.Substring(1)
                
                # Check for common issues
                
                # Encoding issues / BOM - look for non-printable chars before 'using'
                if ($code -match "^[^\x20-\x7E]+using" -or ($code -match "[^\x20-\x7E]" -and $code -match "using")) {
                    $issues += @{
                        Severity = "WARNING"
                        File = $file
                        Line = $currentLine
                        Message = "Encoding/BOM issue detected. Re-save file as UTF-8 without BOM."
                    }
                }
                
                # Empty catch blocks
                if ($code -match "catch\s*\{?\s*$" -or $code -match "catch\s*\([^)]*\)\s*\{?\s*$") {
                    # Check if next lines are empty
                }
                
                # Hardcoded GUIDs
                if ($code -match "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}" -and $code -notmatch "Guid\.(Empty|NewGuid|Parse|TryParse)") {
                    $issues += @{
                        Severity = "INFO"
                        File = $file
                        Line = $currentLine
                        Message = "Hardcoded GUID detected. Consider moving to configuration or generating dynamically for better maintainability."
                    }
                }
                
                # Hardcoded dates in strings
                if ($code -match '"\d{4}-\d{2}-\d{2}T') {
                    $issues += @{
                        Severity = "INFO"
                        File = $file
                        Line = $currentLine
                        Message = "Hardcoded date/time value. Consider using relative dates or configuration for test data."
                    }
                }
                
                # TODO comments
                if ($code -match "//\s*TODO" -or $code -match "//\s*FIXME" -or $code -match "//\s*HACK") {
                    $issues += @{
                        Severity = "INFO"
                        File = $file
                        Line = $currentLine
                        Message = "TODO/FIXME comment found. Consider addressing before merge or creating a ticket."
                    }
                }
                
                # Console.WriteLine in production code
                if ($code -match "Console\.Write" -and $file -notmatch "Test|Spec") {
                    $issues += @{
                        Severity = "WARNING"
                        File = $file
                        Line = $currentLine
                        Message = "Console.WriteLine detected. Use proper logging framework instead."
                    }
                }
                
                # Empty string comparisons
                if ($code -match '==\s*""' -or $code -match '""\s*==') {
                    $issues += @{
                        Severity = "INFO"
                        File = $file
                        Line = $currentLine
                        Message = "Consider using string.IsNullOrEmpty() or string.IsNullOrWhiteSpace() instead of comparing to empty string."
                    }
                }
                
                # Magic numbers
                if ($code -match "=\s*\d{3,}" -and $code -notmatch "const|readonly|enum|\[\d+\]|port|status|code|year|timeout" -and $code -notmatch "//") {
                    $issues += @{
                        Severity = "MINOR"
                        File = $file
                        Line = $currentLine
                        Message = "Magic number detected. Consider extracting to a named constant for better readability."
                    }
                }
                
                # Duplicate using statements (check for System.* without using at start)
                if ($code -match "^using System;" -and $file -match "\.cs$") {
                    # Check if specific usings are also present
                }
                
                # Missing async suffix
                if ($code -match "public\s+(async\s+)?Task" -and $code -match "\s+(\w+)\s*\(" -and $code -notmatch "Async\s*\(") {
                    $methodName = $Matches[1]
                    if ($methodName -and $methodName -notmatch "Async$" -and $code -match "async") {
                        $issues += @{
                            Severity = "MINOR"
                            File = $file
                            Line = $currentLine
                            Message = "Async method should have 'Async' suffix by convention."
                        }
                    }
                }
                
                # Potential null reference
                if ($code -match "\.ToString\(\)" -and $code -notmatch "\?" -and $code -notmatch "!\.") {
                    # Could be null
                }
                
                # Long lines
                if ($code.Length -gt 150) {
                    $issues += @{
                        Severity = "MINOR"
                        File = $file
                        Line = $currentLine
                        Message = "Line exceeds 150 characters. Consider breaking into multiple lines for readability."
                    }
                }
                
                # Multiple statements on one line
                if (($code -split ";").Count -gt 3) {
                    $issues += @{
                        Severity = "MINOR"
                        File = $file
                        Line = $currentLine
                        Message = "Multiple statements on one line. Consider separating for better readability."
                    }
                }
                
                # Commented out code
                if ($code -match "^\s*//\s*(public|private|protected|internal|class|void|async|await|return|if|for|while|try)" -and $code -notmatch "TODO|FIXME|NOTE") {
                    $issues += @{
                        Severity = "INFO"
                        File = $file
                        Line = $currentLine
                        Message = "Commented-out code detected. Remove if no longer needed or add explanation comment."
                    }
                }
                
                # Assert without descriptive message
                if ($code -match 'Assert\.(That|Fail|IsTrue|IsFalse|AreEqual|IsNotNull|IsNull)\s*\([^,]+\)\s*;') {
                    $issues += @{
                        Severity = "MINOR"
                        File = $file
                        Line = $currentLine
                        Message = "Assertion without custom message. Add a descriptive message for better test failure diagnostics."
                    }
                }
                
                # new HttpClient() - should be reused
                if ($code -match "new\s+HttpClient\s*\(" -and $code -notmatch "//") {
                    $issues += @{
                        Severity = "WARNING"
                        File = $file
                        Line = $currentLine
                        Message = "Creating new HttpClient instance. HttpClient should be reused (consider IHttpClientFactory or static instance) to avoid socket exhaustion."
                    }
                }
                
                # Catch Exception (too broad)
                if ($code -match "catch\s*\(\s*Exception\s+") {
                    $issues += @{
                        Severity = "INFO"
                        File = $file
                        Line = $currentLine
                        Message = "Catching base Exception class. Consider catching more specific exception types."
                    }
                }
                
                # String concatenation in loops (potential)
                if ($code -match "\+=\s*[`"']" -or $code -match "\+=\s*\$") {
                    $issues += @{
                        Severity = "INFO"
                        File = $file
                        Line = $currentLine
                        Message = "String concatenation with +=. If in a loop, consider using StringBuilder for better performance."
                    }
                }
                
                # Public fields instead of properties
                if ($code -match "public\s+(string|int|bool|Guid|List|Dictionary|HashSet)\s+\w+\s*;" -and $code -notmatch "const|readonly") {
                    $issues += @{
                        Severity = "INFO"
                        File = $file
                        Line = $currentLine
                        Message = "Public field detected. Consider using a property with { get; set; } instead for encapsulation."
                    }
                }
            }
            elseif (-not $line.StartsWith("-")) {
                $currentLine++
            }
        }
    }
    
    return $issues
}

function Post-MRComment {
    param($details, [string]$body)
    
    $headers = @{ 
        "PRIVATE-TOKEN" = $GitLabToken
        "Content-Type" = "application/json"
    }
    
    $noteUrl = "$($details.BaseUrl)/projects/$($details.ProjectEncoded)/merge_requests/$($details.MrIid)/notes"
    $payload = @{ body = $body } | ConvertTo-Json -Depth 10
    
    Invoke-RestMethod -Uri $noteUrl -Method Post -Headers $headers -Body $payload | Out-Null
}

function Post-LineComment {
    param($details, $issue, $changes)
    
    $headers = @{ 
        "PRIVATE-TOKEN" = $GitLabToken
        "Content-Type" = "application/json"
    }
    
    $change = $changes | Where-Object { $_.new_path -eq $issue.File -or $_.old_path -eq $issue.File } | Select-Object -First 1
    
    if (-not $change) {
        return $false
    }
    
    $discussionUrl = "$($details.BaseUrl)/projects/$($details.ProjectEncoded)/merge_requests/$($details.MrIid)/discussions"
    
    $severityIcon = switch ($issue.Severity) {
        "CRITICAL" { "[CRITICAL]" }
        "WARNING" { "[WARNING]" }
        "INFO" { "[INFO]" }
        "MINOR" { "[MINOR]" }
        default { "[NOTE]" }
    }
    
    $payload = @{
        body = "$severityIcon $($issue.Message)"
        position = @{
            base_sha = $details.MR.diff_refs.base_sha
            start_sha = $details.MR.diff_refs.start_sha
            head_sha = $details.MR.diff_refs.head_sha
            position_type = "text"
            new_path = $change.new_path
            new_line = $issue.Line
        }
    } | ConvertTo-Json -Depth 5
    
    try {
        Invoke-RestMethod -Uri $discussionUrl -Method Post -Headers $headers -Body $payload | Out-Null
        return $true
    }
    catch {
        Write-Host "    [!] Failed to post line comment: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $false
    }
}

function Merge-MR {
    param($details)
    
    $headers = @{ 
        "PRIVATE-TOKEN" = $GitLabToken
        "Content-Type" = "application/json"
    }
    
    $mergeUrl = "$($details.BaseUrl)/projects/$($details.ProjectEncoded)/merge_requests/$($details.MrIid)/merge"
    
    try {
        Invoke-RestMethod -Uri $mergeUrl -Method Put -Headers $headers | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Process-MR {
    param([string]$url)
    
    Write-Host "$(Get-Date -Format 'HH:mm:ss') - Processing: $url" -ForegroundColor Yellow
    
    $parsed = Parse-MRUrl $url
    if (-not $parsed) {
        Write-Host "  [X] Could not parse MR URL" -ForegroundColor Red
        return @{ Success = $false; Summary = "Could not parse URL" }
    }
    
    Write-Host "  -> Fetching MR details..." -ForegroundColor Gray
    try {
        $details = Get-MRDetails $parsed
    }
    catch {
        Write-Host "  [X] Failed to fetch MR: $_" -ForegroundColor Red
        return @{ Success = $false; Summary = "Failed to fetch MR" }
    }
    
    $mr = $details.MR
    $author = $mr.author.name
    $title = $mr.title
    $project = $mr.references.full
    
    Write-Host "  -> MR: $title (by $author)" -ForegroundColor Gray
    Write-Host "  -> Files changed: $($details.Changes.Count)" -ForegroundColor Gray
    
    # Review code
    Write-Host "  -> Analyzing code..." -ForegroundColor Gray
    $issues = Review-CodeChanges $details.Changes $mr
    
    $hasCritical = ($issues | Where-Object { $_.Severity -eq "CRITICAL" }).Count -gt 0
    $shouldMerge = -not $hasCritical
    
    Write-Host "  -> Found $($issues.Count) issues (Critical: $hasCritical)" -ForegroundColor Gray
    
    # Post line comments
    $postedCount = 0
    $failedComments = @()
    
    foreach ($issue in $issues) {
        $posted = Post-LineComment $details $issue $details.Changes
        if ($posted) {
            $postedCount++
            Write-Host "    -> Posted: $($issue.File):$($issue.Line) - $($issue.Severity)" -ForegroundColor DarkGray
        }
        else {
            $failedComments += $issue
        }
    }
    
    # Post summary comment
    $summaryLines = @()
    $summaryLines += "## Code Review"
    $summaryLines += ""
    $summaryLines += "**Reviewed by:** Nika Shengelia & Alfred"
    $summaryLines += "**Date:** $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $summaryLines += ""
    
    if ($issues.Count -eq 0) {
        $summaryLines += "No issues found - code looks good!"
    }
    else {
        $critical = ($issues | Where-Object { $_.Severity -eq "CRITICAL" }).Count
        $warning = ($issues | Where-Object { $_.Severity -eq "WARNING" }).Count
        $info = ($issues | Where-Object { $_.Severity -eq "INFO" }).Count
        $minor = ($issues | Where-Object { $_.Severity -eq "MINOR" }).Count
        
        $summaryLines += "### Issues Found"
        $summaryLines += ""
        $summaryLines += "| Severity | Count |"
        $summaryLines += "|----------|-------|"
        if ($critical -gt 0) { $summaryLines += "| CRITICAL | $critical |" }
        if ($warning -gt 0) { $summaryLines += "| WARNING | $warning |" }
        if ($info -gt 0) { $summaryLines += "| INFO | $info |" }
        if ($minor -gt 0) { $summaryLines += "| MINOR | $minor |" }
        
        if ($failedComments.Count -gt 0) {
            $summaryLines += ""
            $summaryLines += "### Additional Notes (could not post inline)"
            foreach ($fc in $failedComments) {
                $summaryLines += "- **[$($fc.Severity)]** ``$($fc.File):$($fc.Line)`` - $($fc.Message)"
            }
        }
    }
    
    $summaryLines += ""
    $summaryLines += "---"
    if ($shouldMerge) {
        $summaryLines += "**Status:** Approved for merge"
    }
    else {
        $summaryLines += "**Status:** Changes requested - please fix critical issues"
    }
    
    $summaryComment = $summaryLines -join "`n"
    Post-MRComment $details $summaryComment
    
    # Merge or decline
    $action = "reviewed"
    if ($shouldMerge) {
        Write-Host "  -> Merging..." -ForegroundColor Green
        $merged = Merge-MR $details
        if ($merged) {
            $action = "merged"
            Write-Host "  [OK] Merged!" -ForegroundColor Green
        }
        else {
            $action = "approved (manual merge needed)"
            Write-Host "  [OK] Approved (merge manually)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  [X] Changes requested (critical issues)" -ForegroundColor Red
        $action = "changes requested"
    }
    
    # Build summary for done file
    $issuesSummary = if ($issues.Count -eq 0) {
        "no issues"
    }
    else {
        $parts = @()
        $critical = ($issues | Where-Object { $_.Severity -eq "CRITICAL" }).Count
        $warning = ($issues | Where-Object { $_.Severity -eq "WARNING" }).Count
        $info = ($issues | Where-Object { $_.Severity -eq "INFO" }).Count
        $minor = ($issues | Where-Object { $_.Severity -eq "MINOR" }).Count
        if ($critical -gt 0) { $parts += "$critical critical" }
        if ($warning -gt 0) { $parts += "$warning warnings" }
        if ($info -gt 0) { $parts += "$info info" }
        if ($minor -gt 0) { $parts += "$minor minor" }
        $parts -join ", "
    }
    
    return @{
        Success = $true
        Author = $author
        Title = $title
        Project = $project
        Action = $action
        IssuesSummary = $issuesSummary
        IssueCount = $issues.Count
    }
}

# Main loop
while ($true) {
    if (Test-Path $queueFile) {
        $lines = Get-Content $queueFile
        $newLines = @()
        
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
                $newLines += $line
                continue
            }
            
            if ($trimmed -match "merge_requests/\d+") {
                $result = Process-MR $trimmed
                
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
                if ($result.Success) {
                    $logEntry = "$timestamp | $($result.Project) | MR by $($result.Author): `"$($result.Title)`" | $($result.IssuesSummary) | $($result.Action)"
                }
                else {
                    $logEntry = "$timestamp | $trimmed | $($result.Summary)"
                }
                
                Add-Content -Path $doneFile -Value $logEntry
                Write-Host ""
            }
            else {
                $newLines += $line
            }
        }
        
        $newLines | Set-Content $queueFile
    }
    
    Start-Sleep -Seconds 5
}
