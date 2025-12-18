# llama-switcher

A PowerShell utility for switching between GGUF models with llama-server. Works with any front-end that connects to llama.cpp's API (SillyTavern, text-generation-webui, Open WebUI, etc.).

## Features

- Interactive menu to switch models on-the-fly
- Reads GGUF headers directly (no model loading required)
- Caches model metadata for instant subsequent loads
- Per-model context size and GPU layer settings
- Window positioning control

## Requirements

- **Windows PowerShell**
- **llama-server** from [llama.cpp](https://github.com/ggerganov/llama.cpp) (must be in PATH)
- **GGUF models** in a configured directory

## Installation

1. Clone or download this repository
2. Copy `config.example.json` to `config.json`
3. Edit `config.json` with your paths:
   ```json
   {
       "modelsPath": "D:\\path\\to\\your\\models",
       "llamaServerPath": "llama-server",
       "port": 8080,
       "defaultContextSize": 24576,
       "gpuLayers": 40
   }
   ```

## Usage

```powershell
.\llama-switcher.ps1
```

- Select a model number to load it
- **R** - Refresh model list
- **M** - Edit `models.json`
- **Q** - Quit (kills running server)

Currently running model is highlighted in yellow.

## Front-End Integration

1. Run llama-switcher and select a model
2. Configure your front-end to connect to llama.cpp at `http://localhost:8080`
3. Switch models anytime - just select a new one in llama-switcher

### Example Launchers

The included `SillyTavern.ps1` and `SillyTavern.bat` demonstrate how to launch llama-switcher alongside a front-end. Adapt these for your preferred UI:

```powershell
.\SillyTavern.ps1   # PowerShell version
.\SillyTavern.bat   # CMD version
```

Edit the path variables at the top of either script to point to your front-end's startup script.

## Configuration

### config.json

| Setting                | Description                                                                                         |
| ---------------------- | --------------------------------------------------------------------------------------------------- |
| `modelsPath`         | Directory containing GGUF models (searched recursively)                                             |
| `llamaServerPath`    | Path to llama-server executable                                                                     |
| `port`               | Server port (default: 8080)                                                                         |
| `defaultContextSize` | Default context size                                                                                |
| `gpuLayers`          | Default GPU layers to offload (-ngl)                                                                |
| `window`             | Optional:`{ "x": 50, "y": 50, "width": 800, "height": 600, "title": "llama.cpp Model Switcher" }` |

### models.json (auto-generated)

Per-model settings cached after first load:

| Setting                  | Description                                      |
| ------------------------ | ------------------------------------------------ |
| `modelContextSize`     | Model's native max context (from GGUF header)    |
| `preferredContextSize` | Context to actually use (edit to tune per-model) |
| `gpuLayers`            | GPU layers for this model                        |

## How It Works

- Parses GGUF headers directly to read model metadata
- Caches model info in `models.json` for instant loads
- Starts llama-server with selected model (hidden window)
- Kills previous server when switching models
- Binds to `0.0.0.0:8080` for local/network access

## License

MIT
