#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Repository PowerShell syntax' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:ScriptFiles = @(
            Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -Include *.ps1, *.psm1 -File |
                Where-Object {
                    $_.FullName -notmatch '[\\/](\.git|artifacts)[\\/]'
                }
        )
    }

    It 'discovers PowerShell files to parse' {
        $script:ScriptFiles.Count | Should -BeGreaterThan 0
    }

    It 'parses every .ps1 and .psm1 file with zero parser errors' {
        $failures = New-Object System.Collections.Generic.List[string]
        $totalErrors = 0

        foreach ($file in $script:ScriptFiles) {
            $parseErrors = $null
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName,
                [ref]$tokens,
                [ref]$parseErrors
            )
            $count = @($parseErrors).Count
            $totalErrors += $count
            if ($count -gt 0) {
                foreach ($err in $parseErrors) {
                    $failures.Add(('{0}:{1}: {2}' -f $file.FullName, $err.Extent.StartLineNumber, $err.Message)) | Out-Null
                }
            }
        }

        Write-Host ('ParsedFileCount={0}' -f $script:ScriptFiles.Count)
        Write-Host ('ParserErrorCount={0}' -f $totalErrors)
        if ($failures.Count -gt 0) {
            Write-Host ($failures -join [Environment]::NewLine)
        }

        $totalErrors | Should -Be 0
        $failures.Count | Should -Be 0
    }

    It 'specifically parses Test-DismCompatibility.ps1 with zero errors' {
        $path = Join-Path $script:RepoRoot 'scripts\Test-DismCompatibility.ps1'
        Test-Path -LiteralPath $path | Should -BeTrue
        $parseErrors = $null
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        Write-Host ('Test-DismCompatibility PARSER_ERROR_COUNT={0}' -f @($parseErrors).Count)
        @($parseErrors).Count | Should -Be 0
    }
}
