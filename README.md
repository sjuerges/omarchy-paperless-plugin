# Paperless-ngx Omarchy Plugin

A beautiful, highly integrated status bar widget and sliding inbox details panel for [Omarchy](https://omarchy.org/) systems, built to manage your [Paperless-ngx](https://docs.paperless-ngx.com/) document inbox in real time directly from your Wayland top bar.

<img width="1131" height="333" alt="image" src="https://github.com/user-attachments/assets/707e16e0-ad61-475f-97bf-049c8ea56908" />

## Features

- **Top Bar Badge**: Displays a modern, leaf icon  alongside the live count of items currently in your Paperless-ngx inbox.
- **Document Upload**: Click **+ Ajouter des documents** to open a file picker. Select one or more files (PDF, PNG, JPG, TIFF). Files are uploaded sequentially to Paperless via the official API. Status is tracked in real time (Waiting → Uploading → Processing → Done).
- **Task Tracking**: After upload, the plugin polls Paperless tasks to track consumption status (OCR, classification, indexing). Status updates automatically in the panel.
- **Interactive Sliding Preview Panel**: 
  - Left-click on any document's thumbnail to smoothly expand the panel width, opening a large, high-resolution preview with a magnifying glass lens.
  - Clicking the large preview or the thumbnail again instantly slides it closed.
  - Uses highly cached local WebP thumbnails for **instantaneous zero-latency rendering**.
- **Setup Wizard on First Usage**: If credentials aren't configured yet, opening the panel reveals a secure QML setup form. Enter your Server URL and API Token, click **Save & Connect**.
- **Done Action**: A single click on the `Done` button removes the `Inbox` tag from the document, immediately removing it from your top bar badge list.
- **Single-click Deletion / Trash**: A dedicated red `Delete` button instantly moves the document to your server's trash/deletes it.
- **Searchable Correspondent Picker**: Change a document's correspondent on the fly. Dynamically fetches and indexes your full **correspondent database** in a searchable filter box.
- **Dynamic Tag Management**:
  - Horizontal `Flow` layout renders your current tags with their native Paperless-ngx custom background and text colors.
  - Click the `x` delete button on any tag to remove it instantly.
  - Use the `+ Add Tag` dropdown list (which intelligently filters out tags already applied) to assign new tags to your documents.
- **Inline Correspondent Creator**: Type a new name in the text field and press Enter (or click `+ Add Corr`) to instantly create a new correspondent on your server, with visual success/error feedback.

---

## Folder Structure

```
~/.config/omarchy/plugins/paperless/  # Local installation directory
├── manifest.json                    # Plugin entry points and category metadata
├── BarWidget.qml                    # Status bar widget (Badge + click actions)
└── Panel.qml                        # Sliding detailed drawer & setup panel
```

---

## Configuration & Security

The plugin strictly enforces **zero hardcoded credentials/secrets** in its source code, making it 100% compliant with Omarchy security audits.

On first connect, or via the setup form, the configuration is written to:
`~/.config/omarchy/paperless.json`

The JSON structure contains:
```json
{
  "url": "https://paperless.example.com",
  "token": "your_paperless_api_token"
}
```
*The plugin automatically enforces a secure `0600` file permission (readable/writable only by the owner).*

### TLS Certificate (Self-Signed / Private CA)

If your Paperless-ngx instance uses a self-signed or private CA certificate, the plugin will fail API requests with `SSL certificate verify result: self-signed certificate`.

To fix this, export your server's certificate and place it at:
```
~/.config/omarchy/paperless-ca.pem
```

For example:
```bash
openssl s_client -connect your-paperless-host:443 -servername your-paperless-host </dev/null \
  | openssl x509 > ~/.config/omarchy/paperless-ca.pem
chmod 600 ~/.config/omarchy/paperless-ca.pem
```

The plugin will automatically use this CA file for all curl requests when present, without disabling TLS validation.

---

## Installation & Setup

You can install and configure the plugin either directly via the official Omarchy CLI or manually if you prefer to customize the source.

### Method 1: Using the Omarchy CLI (Recommended)

1. **Add and enable the plugin** directly from GitHub:
   ```bash
   omarchy plugin add https://github.com/sjuerges/omarchy-paperless-plugin.git --enable
   ```

2. **Add the widget to your status bar** (for example, in the center section right after the clock):
   ```bash
   omarchy bar put paperless --after omarchy.clock
   ```

### Method 2: Manual Installation (For active development)

1. **Clone the repository** into your local Omarchy plugins directory:
   ```bash
   git clone https://github.com/sjuerges/omarchy-paperless-plugin.git ~/.config/omarchy/plugins/paperless
   ```

2. **Enable the plugin**:
   ```bash
   omarchy plugin enable paperless
   ```

3. **Add the widget to your status bar**:
   ```bash
   omarchy bar put paperless --after omarchy.clock
   ```

Once installed, clicking the widget for the first time will automatically launch the setup wizard so you can enter your server URL and API credentials securely.

---

## Uninstallation & Removal

To completely disable and remove the plugin from your status bar and system:

### Standard Removal (CLI-installed)

1. **Disable the plugin** to stop it and remove it from the running shell:
   ```bash
   omarchy plugin disable paperless
   ```

2. **Remove the plugin files** from the system:
   ```bash
   omarchy plugin remove paperless
   ```

### Manual Removal

1. **Disable the plugin**:
   ```bash
   omarchy plugin disable paperless
   ```

2. **Delete the plugin directory**:
   ```bash
   rm -rf ~/.config/omarchy/plugins/paperless
   ```

---

*Developed with ❤️ by Sebastian and Gemini CLI.*
