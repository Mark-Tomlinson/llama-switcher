# =============================================================================
# Configuration - edit these paths for your installation
# =============================================================================
$LlamaSwitcher = "D:\llama-switcher\llama-switcher.ps1"
$SillyTavern = "D:\SillyTavern\UpdateAndStart.bat"
# =============================================================================

# llama.cpp & SillyTavern - run concurrently in visible CLI windows
$proc1 = Start-Process "$LlamaSwitcher" -PassThru
$proc2 = Start-Process "$SillyTavern" -PassThru
