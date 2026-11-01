param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $repo
try {
    $branch = (git branch --show-current).Trim()
    if ($branch -ne 'personal/stable') {
        throw "请先切换到 personal/stable；当前分支为 $branch。"
    }
    $changes = @(git status --porcelain)
    if ($changes.Count -gt 0) {
        throw '工作区必须干净；先提交或暂存当前修改，再运行上游更新。'
    }

    git config rerere.enabled true
    git remote get-url upstream | Out-Null
    git fetch upstream "refs/tags/$Version"
    if ($LASTEXITCODE -ne 0) { throw "获取官方标签 $Version 失败。" }

    $upgradeBranch = "upgrade/$Version"
    git show-ref --verify --quiet "refs/heads/$upgradeBranch"
    if ($LASTEXITCODE -eq 0) { throw "分支 $upgradeBranch 已存在，请先检查现有升级工作。" }

    git switch -c $upgradeBranch personal/stable
    if ($LASTEXITCODE -ne 0) { throw "创建分支 $upgradeBranch 失败。" }
    git merge --no-ff --no-edit "refs/tags/$Version"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning '合并存在冲突。保留 upgrade 分支，解决后运行测试和双平台构建；不要覆盖 personal/stable。'
        exit 1
    }

    Write-Host "已将官方 $Version 合并到 $upgradeBranch。请先审阅差异、运行回归和 Windows/Android 构建，通过后再合并回 personal/stable。"
} finally {
    Pop-Location
}
