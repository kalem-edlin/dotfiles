# Cursor Configuration

## Installing VSIX Extensions

Some extensions are not available in Cursor's marketplace and need to be installed manually from VSIX files.

### VSIX Files

Download from: https://drive.google.com/file/d/1NY1BotZ_6Ohtc_DmF4fuOrwnONg3ddzb/view?usp=sharing

### Installation Steps

1. **Download the VSIX file** from the Google Drive link above

2. **Install in Cursor:**
   - Press `Cmd+Shift+P` (Command Palette)
   - Type: `Extensions: Install from VSIX...`
   - Select the downloaded `.vsix` file

3. **Reload Cursor:**
   - Press `Cmd+Shift+P`
   - Type: `Developer: Reload Window`

### Important Notes

⚠️ Some extensions (like vibrancy) modify core Cursor files. Cursor may show a "corrupt installation" warning - this is **expected and safe to dismiss**.

⚠️ After Cursor updates, you may need to reinstall VSIX extensions as updates can overwrite patched files.
