# Load configuration from config.json
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir "config.json"

if (-not (Test-Path $configPath)) {
	Write-Host "ERROR: config.json not found at $configPath" -ForegroundColor Red
	Write-Host "Please create config.json with your settings." -ForegroundColor Yellow
	Read-Host "Press Enter to exit"
	exit
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

$modelsPath = $config.modelsPath
$llamaServerPath = $config.llamaServerPath
$port = $config.port
$defaultContextSize = $config.defaultContextSize
$gpuLayers = $config.gpuLayers
# Window settings - each property is optional
$windowConfig = $config.window

$Host.UI.RawUI.WindowTitle = "llama Switcher"

# GGUF Header Parser - extracts context_length from model metadata
function Get-GGUFContextLength {
	param([string]$FilePath)

	try {
		$stream = [System.IO.File]::OpenRead($FilePath)
		$reader = New-Object System.IO.BinaryReader($stream)

		# Read magic (4 bytes) - should be "GGUF"
		$magic = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
		if ($magic -ne "GGUF") {
			$reader.Close(); $stream.Close()
			return $null
		}

		# Read version (uint32), tensor count (uint64), metadata count (uint64)
		$version = $reader.ReadUInt32()
		$tensorCount = $reader.ReadUInt64()
		$metadataCount = $reader.ReadUInt64()

		# Parse metadata key-value pairs
		for ($i = 0; $i -lt $metadataCount; $i++) {
			# Key: length (uint64) + string
			$keyLen = $reader.ReadUInt64()
			$keyBytes = $reader.ReadBytes([int]$keyLen)
			$key = [System.Text.Encoding]::UTF8.GetString($keyBytes)

			# Value type (uint32)
			$valueType = $reader.ReadUInt32()

			# Check if this is the context_length key
			$isContextLength = $key -like "*.context_length"

			# Read value based on type
			switch ($valueType) {
				0  { $val = $reader.ReadByte() }		# UINT8
				1  { $val = $reader.ReadSByte() }		# INT8
				2  { $val = $reader.ReadUInt16() }		# UINT16
				3  { $val = $reader.ReadInt16() }		# INT16
				4  { $val = $reader.ReadUInt32() }		# UINT32
				5  { $val = $reader.ReadInt32() }		# INT32
				6  { $val = $reader.ReadSingle() }		# FLOAT32
				7  { $val = $reader.ReadByte() }		# BOOL
				8  {									# STRING
					$strLen = $reader.ReadUInt64()
					$reader.ReadBytes([int]$strLen) | Out-Null
				}
				9  {									# ARRAY
					$arrType = $reader.ReadUInt32()
					$arrCount = $reader.ReadUInt64()
					# Skip array elements based on type
					$elemSize = switch ($arrType) {
						0 { 1 } 1 { 1 } 2 { 2 } 3 { 2 } 4 { 4 } 5 { 4 }
						6 { 4 } 7 { 1 } 10 { 8 } 11 { 8 } 12 { 8 }
						8 { -1 }	# String array - variable size
						default { 4 }
					}
					if ($elemSize -gt 0) {
						$reader.ReadBytes([int]($arrCount * $elemSize)) | Out-Null
					} else {
						# String array - read each string
						for ($j = 0; $j -lt $arrCount; $j++) {
							$sLen = $reader.ReadUInt64()
							$reader.ReadBytes([int]$sLen) | Out-Null
						}
					}
				}
				10 { $val = $reader.ReadUInt64() }				  # UINT64
				11 { $val = $reader.ReadInt64() }				   # INT64
				12 { $val = $reader.ReadDouble() }				  # FLOAT64
			}

			if ($isContextLength) {
				$reader.Close(); $stream.Close()
				return [int]$val
			}
		}

		$reader.Close(); $stream.Close()
		return $null
	}
	catch {
		if ($reader) { $reader.Close() }
		if ($stream) { $stream.Close() }
		return $null
	}
}

# Load or create models cache
$modelsCachePath = Join-Path $scriptDir "models.json"
if (Test-Path $modelsCachePath) {
	$modelsCache = Get-Content $modelsCachePath -Raw | ConvertFrom-Json
	# Convert to hashtable for easier manipulation
	$modelsCacheHash = @{}
	$modelsCache.PSObject.Properties | ForEach-Object { $modelsCacheHash[$_.Name] = $_.Value }
} else {
	$modelsCacheHash = @{}
}
$cacheModified = $false

# Helper to get context size for a model (from cache or by parsing)
function Get-ModelContextSize {
	param([System.IO.FileInfo]$Model)

	$path = $Model.FullName
	$fileSize = $Model.Length

	# Check cache - valid if exists and file size matches
	if ($modelsCacheHash.ContainsKey($path)) {
		$cached = $modelsCacheHash[$path]
		if ($cached.fileSize -eq $fileSize) {
			return $cached.modelContextSize
		}
	}

	# Not in cache or file changed - parse GGUF header
	$contextSize = Get-GGUFContextLength -FilePath $path
	if ($null -eq $contextSize) { $contextSize = $defaultContextSize }

	# Update cache - set preferredSize and gpuLayers to defaults for easy editing
	$preferredSize = [math]::Min($contextSize, $defaultContextSize)
	$modelsCacheHash[$path] = [PSCustomObject]@{
		modelContextSize = $contextSize
		preferredContextSize = $preferredSize
		gpuLayers = $gpuLayers
		fileSize = $fileSize
		queriedAt = (Get-Date -Format "yyyy-MM-dd")
	}
	$script:cacheModified = $true

	return $contextSize
}

# Helper to save cache if modified
function Save-ModelsCache {
	if ($script:cacheModified) {
		$modelsCacheHash | ConvertTo-Json -Depth 3 | Set-Content $modelsCachePath -Encoding UTF8
		$script:cacheModified = $false
	}
}

# Scan models and update cache for any new/changed files
Write-Host "Scanning models..." -ForegroundColor DarkGray
$allModels = Get-ChildItem -Path $modelsPath -Filter "*.gguf" -Recurse |
			 Where-Object { $_.Name -notlike "*mmproj*" } |
			 Sort-Object Name

$newModels = @()
foreach ($model in $allModels) {
	$path = $model.FullName
	$fileSize = $model.Length
	if (-not $modelsCacheHash.ContainsKey($path) -or $modelsCacheHash[$path].fileSize -ne $fileSize) {
		$newModels += $model
	}
}

if ($newModels.Count -gt 0) {
	Write-Host "Querying metadata for $($newModels.Count) new/changed model(s)..." -ForegroundColor Yellow
	$count = 0
	foreach ($model in $newModels) {
		$count++
		Write-Host "  [$count/$($newModels.Count)] $($model.BaseName)" -ForegroundColor DarkGray
		Get-ModelContextSize -Model $model | Out-Null
	}
	Save-ModelsCache
	Write-Host "Done!" -ForegroundColor Green
	Start-Sleep -Seconds 1
}

# Bring Llama Switcher to the top
Add-Type @"
	using System;
	using System.Runtime.InteropServices;
	public class Window {
		[DllImport("kernel32.dll")]
		public static extern IntPtr GetConsoleWindow();
		[DllImport("user32.dll")]
		public static extern bool SetForegroundWindow(IntPtr hWnd);
		[DllImport("user32.dll")]
		public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
		public const int SW_RESTORE = 9;
	}
"@
$consolePtr = [Window]::GetConsoleWindow()
[Window]::ShowWindow($consolePtr, [Window]::SW_RESTORE)  # Unminimize if minimized
[Window]::SetForegroundWindow($consolePtr)  # Bring to front

# Set console window position/size (only for properties specified in config)
if ($windowConfig -and $windowConfig -ne "auto") {
	Add-Type -Name Window -Namespace Console -MemberDefinition '
		[DllImport("Kernel32.dll")] public static extern IntPtr GetConsoleWindow();
		[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int W, int H, bool bRepaint);
		[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
		[StructLayout(LayoutKind.Sequential)]
		public struct RECT { public int Left, Top, Right, Bottom; }
	'
	$consoleHWND = [Console.Window]::GetConsoleWindow()

	# Get current window position/size
	$rect = New-Object Console.Window+RECT
	[Console.Window]::GetWindowRect($consoleHWND, [ref]$rect) | Out-Null
	$currentX = $rect.Left
	$currentY = $rect.Top
	$currentWidth = $rect.Right - $rect.Left
	$currentHeight = $rect.Bottom - $rect.Top

	# Override only specified values
	$newTitle = if ($null -ne $windowConfig.title) { $Host.UI.RawUI.WindowTitle = $windowConfig.title }
	$newX = if ($null -ne $windowConfig.x) { $windowConfig.x } else { $currentX }
	$newY = if ($null -ne $windowConfig.y) { $windowConfig.y } else { $currentY }
	$newWidth = if ($null -ne $windowConfig.width) { $windowConfig.width } else { $currentWidth }
	$newHeight = if ($null -ne $windowConfig.height) { $windowConfig.height } else { $currentHeight }

	# Only move if at least one property was specified
	if ($null -ne $windowConfig.x -or $null -ne $windowConfig.y -or $null -ne $windowConfig.width -or $null -ne $windowConfig.height) {
		[Console.Window]::MoveWindow($consoleHWND, $newX, $newY, $newWidth, $newHeight, $true)
	}
}

$currentProcess = $null	 # Track current llama.cpp process
$currentModelIndex = -1	 # Track which model is running
$script:runningContextSize = $null  # Track context size of running model
$script:runningModelMax = $null	 # Track max context of running model

# #########################
#		MAIN LOOP
# Loop with menu until 'Q'
# #########################
while ($true) {
	Clear-Host
	Write-Host "=== llama.cpp Model Switcher ===" -ForegroundColor Cyan
	Write-Host ""
	
	if ($currentProcess -and !$currentProcess.HasExited) {
		Write-Host "[Server Running on port $port]" -ForegroundColor Green
		if ($currentModelIndex -ge 0) {
			$models = Get-ChildItem -Path $modelsPath -Filter "*.gguf" -Recurse |
					  Where-Object { $_.Name -notlike "*mmproj*" } |
					  Sort-Object Name
			Write-Host "Current Model: $($models[$currentModelIndex].BaseName)" -ForegroundColor Green
			if ($script:runningContextSize -and $script:runningModelMax) {
				Write-Host "Context: $($script:runningContextSize) (model max: $($script:runningModelMax))" -ForegroundColor DarkGray
			}
		}
		Write-Host ""
	}
	
	# Get all GGUF files recursively, excluding mmproj files
	$models = Get-ChildItem -Path $modelsPath -Filter "*.gguf" -Recurse | 
			  Where-Object { $_.Name -notlike "*mmproj*" } | 
			  Sort-Object Name
	
	if ($models.Count -eq 0) {
		Write-Host "No .gguf files found in $modelsPath" -ForegroundColor Red
		Read-Host "Press Enter to exit"
		exit
	}
	
	# Display models with context size
	for ($i = 0; $i -lt $models.Count; $i++) {
		$displayName = $models[$i].BaseName  # Filename without .gguf
		$modelPath = $models[$i].FullName
		$maxCtx = Get-ModelContextSize -Model $models[$i]

		# Get preferred size from cache
		$prefCtx = $defaultContextSize
		if ($modelsCacheHash.ContainsKey($modelPath) -and $modelsCacheHash[$modelPath].preferredContextSize) {
			$prefCtx = $modelsCacheHash[$modelPath].preferredContextSize
		} else {
			$prefCtx = [math]::Min($maxCtx, $defaultContextSize)
		}

		# Format for display
		$prefDisplay = if ($prefCtx -ge 1024) { "$([math]::Round($prefCtx/1024))K" } else { $prefCtx }
		$maxDisplay = if ($maxCtx -ge 1024) { "$([math]::Round($maxCtx/1024))K" } else { $maxCtx }
		$isRunning = $i -eq $currentModelIndex -and $currentProcess -and !$currentProcess.HasExited

		# Highlight the currently running model in yellow
		if ($isRunning) {
			Write-Host "$($i + 1). $displayName " -ForegroundColor Yellow -NoNewline
		} else {
			Write-Host "$($i + 1). $displayName " -NoNewline
		}
		Write-Host "(ctx: $prefDisplay, max: $maxDisplay)" -ForegroundColor DarkGray
	}
	Write-Host ""
	Write-Host "R. Refresh models" -ForegroundColor Yellow
	Write-Host "M. Edit models.json" -ForegroundColor Yellow
	Write-Host "Q. Quit" -ForegroundColor Yellow
	Write-Host ""

	$choice = Read-Host "Select a model number or R/M/Q"

	if ($choice -eq "R" -or $choice -eq "r") {
		Write-Host "Refreshing..." -ForegroundColor Yellow

		# Reload models.json from disk (picks up manual edits)
		if (Test-Path $modelsCachePath) {
			$modelsCache = Get-Content $modelsCachePath -Raw | ConvertFrom-Json
			$modelsCacheHash = @{}
			$modelsCache.PSObject.Properties | ForEach-Object { $modelsCacheHash[$_.Name] = $_.Value }
			Write-Host "Reloaded models.json" -ForegroundColor DarkGray
		}

		# Rescan for new/changed model files
		$allModels = Get-ChildItem -Path $modelsPath -Filter "*.gguf" -Recurse |
					 Where-Object { $_.Name -notlike "*mmproj*" } |
					 Sort-Object Name
		$newModels = @()
		foreach ($model in $allModels) {
			$path = $model.FullName
			$fileSize = $model.Length
			if (-not $modelsCacheHash.ContainsKey($path) -or $modelsCacheHash[$path].fileSize -ne $fileSize) {
				$newModels += $model
			}
		}
		if ($newModels.Count -gt 0) {
			Write-Host "Found $($newModels.Count) new/changed model(s)..." -ForegroundColor Yellow
			$count = 0
			foreach ($model in $newModels) {
				$count++
				Write-Host "  [$count/$($newModels.Count)] $($model.BaseName)" -ForegroundColor DarkGray
				Get-ModelContextSize -Model $model | Out-Null
			}
			Save-ModelsCache
		}
		Start-Sleep -Seconds 1
		continue
	}

	if ($choice -eq "M" -or $choice -eq "m") {
		Start-Process cmd.exe -ArgumentList "/c start `"`" `"$modelsCachePath`"" -WindowStyle Hidden
		continue
	}

	if ($choice -eq "Q" -or $choice -eq "q") {
		Save-ModelsCache
		if ($currentProcess -and !$currentProcess.HasExited) {
			Write-Host "Stopping server..." -ForegroundColor Yellow
			Stop-Process -Id $currentProcess.Id -Force
		}
		exit
	}
	
	$index = [int]$choice - 1
	
	if ($index -ge 0 -and $index -lt $models.Count) {
		$selectedModel = $models[$index]
		
		# Kill existing server
		if ($currentProcess -and !$currentProcess.HasExited) {
			Write-Host "Stopping current server..." -ForegroundColor Yellow
			Stop-Process -Id $currentProcess.Id -Force
			Start-Sleep -Seconds 1
		}
		
		# Start new server - use per-model settings if set, otherwise defaults
		$modelPath = $selectedModel.FullName
		$modelContextSize = Get-ModelContextSize -Model $selectedModel
		$preferredSize = $null
		$modelGpuLayers = $gpuLayers
		if ($modelsCacheHash.ContainsKey($modelPath)) {
			if ($modelsCacheHash[$modelPath].preferredContextSize) {
				$preferredSize = $modelsCacheHash[$modelPath].preferredContextSize
			}
			if ($modelsCacheHash[$modelPath].gpuLayers) {
				$modelGpuLayers = $modelsCacheHash[$modelPath].gpuLayers
			}
		}
		$effectiveContext = if ($preferredSize) { $preferredSize } else { [math]::Min($modelContextSize, $defaultContextSize) }
		$script:runningContextSize = $effectiveContext
		$script:runningModelMax = $modelContextSize
		Write-Host "Starting server with: $($selectedModel.BaseName)" -ForegroundColor Green
		Write-Host "Context: $effectiveContext (max: $modelContextSize) | GPU Layers: $modelGpuLayers" -ForegroundColor DarkGray
		$currentProcess = Start-Process -FilePath $llamaServerPath `
			-ArgumentList "-m", $selectedModel.FullName, "-c", $effectiveContext, "-ngl", $modelGpuLayers, "--port", $port, "--host", "0.0.0.0" `
			-PassThru -WindowStyle Hidden
		
		# Track the current model
		$currentModelIndex = $index
		
		Start-Sleep -Seconds 2
		Write-Host "Server started! Connect SillyTavern to http://localhost:$port" -ForegroundColor Green
		Start-Sleep -Seconds 4

	} else {
		Write-Host "Invalid selection" -ForegroundColor Red
		Start-Sleep -Seconds 1
	}
}