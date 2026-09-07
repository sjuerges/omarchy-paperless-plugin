# Paperless-ngx Omarchy Plugin

A beautiful, highly integrated status bar widget and sliding inbox details panel for [Omarchy](https://omarchy.org/) systems, built to manage your [Paperless-ngx](https://docs.paperless-ngx.com/) document inbox in real time directly from your Wayland top bar.

<img width="1131" height="333" alt="image" src="https://github.com/user-attachments/assets/707e16e0-ad61-475f-97bf-049c8ea56908" />

## Features

- **Top Bar Badge**: Displays a modern, leaf icon  alongside the live count of items currently in your Paperless-ngx inbox.
- **Interactive Sliding Preview Panel**: 
  - Left-click on any document's thumbnail to smoothly expand the panel width from a snug `720px` to a generous `1120px`, opening a large, high-resolution preview of the document.
  - Clicking the large preview or the thumbnail again instantly slides it closed.
  - Uses highly cached local `/tmp/` WebP thumbnails for **instantaneous zero-latency rendering** (no network spinner delay).
- **Setup Wizard on First Usage**: If credentials aren't configured yet, opening the panel reveals a sleek, secure QML setup form. Simply enter your Server URL and API Token, click **Save & Connect**, and the plugin securely writes the configuration file and connects.
- **Done Action**: A single click on the `Done` button removes the `Inbox` tag from the document, immediately removing it from your top bar badge list.
- **Single-click Deletion / Trash**: A dedicated red `Delete` button instantly moves the document to your server's trash/deletes it.
- **Searchable Correspondent Picker**: Change a document's correspondent on the fly. Dynamically fetches and indexes your full **correspondent database** in a searchable filter box.
- **Dynamic Tag Management**:
  - Horizontal `Flow` layout renders your current tags with their native Paperless-ngx custom background and text colors.
  - Click the `x` delete button on any tag to remove it instantly.
  - Use the `+ Add Tag` dropdown list (which intelligently filters out tags already applied) to assign new tags to your documents.
- **Inline Correspondent Creator**: Type a new name in the text field at the top and press Enter (or click `+ Add Corr`) to instantly create a new correspondent on your server, immediately refreshing and syncing across all dropdowns.

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

---

*Developed with  by Sebastian and Gemini CLI.*
