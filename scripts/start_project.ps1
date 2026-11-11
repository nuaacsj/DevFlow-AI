param(
    [int]$BackendPort = 8000,
    [int]$FrontendPort = 3000
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerBin = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'
    if (-not (Test-Path -LiteralPath (Join-Path $dockerBin 'docker.exe'))) {
        throw '未找到 Docker Desktop，请先安装 Docker Desktop。'
    }
    $env:Path = "$dockerBin;$env:Path"
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$logDirectory = Join-Path $projectRoot '.data'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

function Test-Endpoint([string]$Url) {
    try { return (Invoke-WebRequest -Uri $Url -TimeoutSec 3 -UseBasicParsing).StatusCode -eq 200 }
    catch { return $false }
}

Push-Location $projectRoot
try {
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        docker desktop start
        if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop 启动失败。' }
    }
    docker compose up -d postgres etcd minio milvus
    if ($LASTEXITCODE -ne 0) { throw 'Docker 服务启动失败。' }
    $storageReady = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        docker compose exec -T postgres pg_isready -U devflow -d devflow *> $null
        if ($LASTEXITCODE -eq 0 -and (Test-Endpoint 'http://127.0.0.1:9091/healthz')) {
            $storageReady = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $storageReady) { throw '数据库或 Milvus 未就绪，请运行 docker compose logs 检查。' }

    if (-not (Test-Endpoint "http://127.0.0.1:$BackendPort/health")) {
        $pythonPath = Join-Path $projectRoot 'backend\.venv\Scripts\python.exe'
        Start-Process -FilePath $pythonPath `
            -ArgumentList @('-m', 'uvicorn', 'app.main:app', '--host', '127.0.0.1', '--port', "$BackendPort") `
            -WorkingDirectory (Join-Path $projectRoot 'backend') -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $logDirectory 'docker-backend.out.log') `
            -RedirectStandardError (Join-Path $logDirectory 'docker-backend.err.log') | Out-Null
    }
    if (-not (Test-Endpoint "http://127.0.0.1:$FrontendPort")) {
        $nodePath = (Get-Command node -ErrorAction Stop).Source
        Start-Process -FilePath $nodePath `
            -ArgumentList @('node_modules/next/dist/bin/next', 'dev', '--hostname', '127.0.0.1', '--port', "$FrontendPort") `
            -WorkingDirectory (Join-Path $projectRoot 'frontend') -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $logDirectory 'docker-frontend.out.log') `
            -RedirectStandardError (Join-Path $logDirectory 'docker-frontend.err.log') | Out-Null
    }
    $applicationReady = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        if ((Test-Endpoint "http://127.0.0.1:$BackendPort/health") -and (Test-Endpoint "http://127.0.0.1:$FrontendPort")) {
            $applicationReady = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $applicationReady) { throw "应用未就绪，请查看 $logDirectory 中的 docker-*.log。" }
    Write-Host "DevFlow AI 已启动：http://127.0.0.1:$FrontendPort"
    Write-Host "API 文档：http://127.0.0.1:$BackendPort/docs"
}
finally { Pop-Location }
