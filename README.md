# Code Review Watcher

A PowerShell script that watches a queue file for GitLab MR links, automatically reviews the code, posts inline comments, and merges or requests changes.

## Setup

1. Open [config.ps1](config.ps1) and set your GitLab personal access token:
   ```powershell
   $GitLabToken = "your-gitlab-token-here"
   ```

## How to Use

1. Open [review-queue.txt](review-queue.txt)
2. Paste your GitLab merge request link on a new line, for example:
   ```
   https://gitlab.com/your-group/your-project/-/merge_requests/123
   ```
3. Save the file
4. Run the watcher:
   - **Windows:** Double-click [Start-Watcher.bat](Start-Watcher.bat)
   - **PowerShell:** Run `.\watch-reviews.ps1`

The script will pick up the link within a few seconds, review the MR, post comments, and log the result to [review-done.txt](review-done.txt).

## What It Checks

- Encoding / BOM issues
- Hardcoded GUIDs and dates
- `Console.WriteLine` in non-test code
- `new HttpClient()` instances (socket exhaustion risk)
- Catching base `Exception` class
- Missing `Async` suffix on async methods
- Magic numbers, long lines, public fields
- TODO/FIXME/HACK comments
- Commented-out code
- Assertions without a descriptive message

## Notes

- Lines starting with `#` in the queue file are ignored
- Processed links are moved to `review-done.txt` automatically
- If no critical issues are found the MR is merged automatically; otherwise changes are requested
- Keep `config.ps1` out of version control — it contains your API token
