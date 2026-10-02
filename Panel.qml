import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "paperless"
  ipcTarget: "paperless"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property string paperlessUrl: ""
  property string paperlessToken: ""
  property var correspondents: []
  property var tags: []
  property var inboxDocuments: []
  property int inboxCount: 0
  property string barText: inboxCount > 0 ? " " + inboxCount : ""

  property var correspondentOptions: []
  property int inboxTagId: 1
  property bool isFetching: false
  property int thumbBuster: 0
  property int previewDocId: 0

  readonly property string thumbDir: (Quickshell.env("XDG_RUNTIME_DIR") ? Quickshell.env("XDG_RUNTIME_DIR") : (Quickshell.env("HOME") || "") + "/.cache") + "/omarchy/paperless_thumbs"

  readonly property real targetWidth: Style.space(720) + (previewDocId !== 0 ? largePreview.width + Style.space(14) : 0)
  property real currentPanelWidth: Style.space(720)

  Behavior on currentPanelWidth {
    NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
  }

  onTargetWidthChanged: currentPanelWidth = targetWidth

  property var openDropdownsList: []
  readonly property bool someDropdownOpen: openDropdownsList.length > 0

  // --- Upload queue ---
  property var uploadQueue: []
  property bool isUploading: false
  property string corrFeedback: ""
  property bool corrFeedbackIsError: false

  readonly property var supportedFormats: ["pdf", "png", "jpg", "jpeg", "tiff", "tif"]

  onOpenedChanged: {
    if (opened) {
      root.refresh()
    } else {
      root.previewDocId = 0
    }
  }

  function registerDropdownOpen(dropdown, isOpen) {
    var index = openDropdownsList.indexOf(dropdown)
    if (isOpen) {
      if (index === -1) {
        openDropdownsList.push(dropdown)
        root.openDropdownsList = openDropdownsList.slice()
      }
    } else {
      if (index !== -1) {
        openDropdownsList.splice(index, 1)
        root.openDropdownsList = openDropdownsList.slice()
      }
    }
  }

  function rebuildCorrespondentOptions() {
    var opts = []
    opts.push({ value: "", label: "None" })
    for (var i = 0; i < root.correspondents.length; i++) {
      opts.push({
        value: String(root.correspondents[i].id),
        label: root.correspondents[i].name
      })
    }
    root.correspondentOptions = opts
  }

  function getTagOptionsForDoc(docTags) {
    var opts = []
    opts.push({ value: "+ Add Tag", label: "+ Add Tag" })
    for (var i = 0; i < root.tags.length; i++) {
      var t = root.tags[i]
      if (docTags.indexOf(t.id) === -1) {
        opts.push({
          value: String(t.id),
          label: t.name
        })
      }
    }
    return opts
  }

  function getTagObj(tagId) {
    for (var i = 0; i < root.tags.length; i++) {
      if (root.tags[i].id === tagId) return root.tags[i]
    }
    return null
  }

  function isUrlSecure(url) {
    if (!url || typeof url !== "string") {
      return false
    }

    var cleanUrl = url.trim()
    if (!cleanUrl) {
      return false
    }

    // Never allow credentials/userinfo or '@' in the URL to prevent host confusion
    if (cleanUrl.indexOf("@") !== -1) {
      return false
    }

    // Never allow query strings or fragments in Paperless base URL
    if (cleanUrl.indexOf("?") !== -1 || cleanUrl.indexOf("#") !== -1) {
      return false
    }

    // Reject whitespace, quotes, backslashes, and control characters
    if (/[\s\r\n"'\\]/.test(cleanUrl) || /[\x00-\x1f\x7f]/.test(cleanUrl)) {
      return false
    }

    try {
      var parsed = new URL(cleanUrl)

      // Strict protocol check: HTTPS or HTTP only
      if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
        return false
      }

      // Reject userinfo if parsed by URL
      if (parsed.username || parsed.password) {
        return false
      }

      // Hostname must be present
      if (!parsed.hostname) {
        return false
      }

      // For plain HTTP, ONLY allow localhost loopback addresses
      if (parsed.protocol === "http:") {
        var host = parsed.hostname.toLowerCase()
        if (host !== "localhost" && host !== "127.0.0.1" && host !== "::1" && host !== "[::1]") {
          return false
        }
      }

      // If port is specified, validate it is numeric and within valid port range 1-65535
      if (parsed.port) {
        var portNum = parseInt(parsed.port, 10)
        if (isNaN(portNum) || portNum < 1 || portNum > 65535 || String(portNum) !== parsed.port) {
          return false
        }
      }

      return true
    } catch (e) {
      return false
    }
  }

  function apiRequest(method, endpoint, bodyData, onSuccess, onFailure) {
    if (!root.paperlessUrl || !root.paperlessToken) {
      if (onFailure) onFailure("Not configured")
      return
    }

    if (!root.isUrlSecure(root.paperlessUrl)) {
      console.log("Error: Insecure paperless URL configured:", root.paperlessUrl)
      if (onFailure) onFailure("Insecure URL")
      return
    }

    var cmd = "set -o pipefail\n"
            + "read -r TOKEN\n"
            + "read -r BODY\n"
            + "METHOD=\"$1\"\n"
            + "URL=\"$2\"\n"
            + "BODY_TEMP=\"\"\n"
            + "if [ -n \"$BODY\" ]; then\n"
            + "  BODY_TEMP=$(mktemp)\n"
            + "  chmod 600 \"$BODY_TEMP\"\n"
            + "  printf '%s' \"$BODY\" > \"$BODY_TEMP\"\n"
            + "fi\n"
            + "CURL_CFG=$(mktemp)\n"
            + "HEADER_OUT=$(mktemp)\n"
            + "TEMP_OUT=$(mktemp)\n"
            + "chmod 600 \"$CURL_CFG\" \"$HEADER_OUT\" \"$TEMP_OUT\"\n"
            + "cleanup() {\n"
            + "  rm -f \"$CURL_CFG\" \"$BODY_TEMP\" \"$HEADER_OUT\" \"$TEMP_OUT\"\n"
            + "}\n"
            + "trap cleanup EXIT\n"
            + "printf 'request = \"%s\"\\nurl = \"%s\"\\nheader = \"Authorization: Token %s\"\\n' \"$METHOD\" \"$URL\" \"$TOKEN\" > \"$CURL_CFG\"\n"
            + "CA_FILE=\"$HOME/.config/omarchy/paperless-ca.pem\"\n"
            + "if [ -r \"$CA_FILE\" ]; then printf 'cacert = \"%s\"\\n' \"$CA_FILE\" >> \"$CURL_CFG\"; fi\n"
            + "if [ -n \"$BODY_TEMP\" ]; then\n"
            + "  printf 'header = \"Content-Type: application/json\"\\ndata-binary = \"@%s\"\\n' \"$BODY_TEMP\" >> \"$CURL_CFG\"\n"
            + "fi\n"
            + "if curl -fsS --connect-timeout 5 --max-time 15 --config \"$CURL_CFG\" -D \"$HEADER_OUT\" | head -c 5242881 > \"$TEMP_OUT\"; then\n"
            + "  HTTP_CODE=\"\"\n"
            + "  if [ -s \"$HEADER_OUT\" ]; then\n"
            + "    read -r _ HTTP_CODE _ < \"$HEADER_OUT\"\n"
            + "    HTTP_CODE=$(echo \"$HTTP_CODE\" | tr -d '\\r\\n[:space:]')\n"
            + "  fi\n"
            + "  SIZE=$(stat -c %s \"$TEMP_OUT\")\n"
            + "  if [ \"$SIZE\" -gt 5242880 ]; then\n"
            + "    echo \"Error: API response exceeded safety limit of 5MB\" >&2\n"
            + "    exit 2\n"
            + "  fi\n"
            + "  if [ -n \"$HTTP_CODE\" ] && [ \"$HTTP_CODE\" -ge 200 ] && [ \"$HTTP_CODE\" -lt 300 ]; then\n"
            + "    cat \"$TEMP_OUT\"\n"
            + "    exit 0\n"
            + "  else\n"
            + "    echo \"HTTP Error: $HTTP_CODE\" >&2\n"
            + "    cat \"$TEMP_OUT\" >&2\n"
            + "    exit 3\n"
            + "  fi\n"
            + "else\n"
            + "  echo \"Curl execution failed\" >&2\n"
            + "  exit 4\n"
            + "fi"

    var base = root.paperlessUrl.trim()
    while (base.endsWith("/")) {
      base = base.substring(0, base.length - 1)
    }
    var url = base + endpoint
    var args = ["bash", "-c", cmd, "api-request-script", method, url]

    var proc = apiProcComponent.createObject(root, {
      "command": args,
      "method": method,
      "onSuccess": onSuccess,
      "onFailure": onFailure
    })

    proc.stdinEnabled = true
    proc.running = true
    proc.write(root.paperlessToken + "\n" + (bodyData ? JSON.stringify(bodyData) : "") + "\n")
    proc.stdinEnabled = false
  }

  // --- Upload a document via multipart/form-data ---
  function uploadDocument(filePath, correspondentId) {
    if (!root.paperlessUrl || !root.paperlessToken) {
      return
    }

    var cmd = "read -r TOKEN\n"
            + "FILE_PATH=\"$1\"\n"
            + "CORR=\"$2\"\n"
            + "URL=\"$3\"\n"
            + "if [ ! -f \"$FILE_PATH\" ] || [ ! -r \"$FILE_PATH\" ]; then\n"
            + "  echo \"File not found or not readable: $FILE_PATH\" >&2\n"
            + "  exit 1\n"
            + "fi\n"
            + "TEMP_OUT=$(mktemp)\n"
            + "HEADER_OUT=$(mktemp)\n"
            + "chmod 600 \"$TEMP_OUT\" \"$HEADER_OUT\"\n"
            + "cleanup() {\n"
            + "  rm -f \"$TEMP_OUT\" \"$HEADER_OUT\"\n"
            + "}\n"
            + "trap cleanup EXIT\n"
            + "CA_ARGS=()\n"
            + "CA_FILE=\"$HOME/.config/omarchy/paperless-ca.pem\"\n"
            + "if [ -r \"$CA_FILE\" ]; then CA_ARGS=(--cacert \"$CA_FILE\"); fi\n"
            + "EXTRA_FORM=\"\"\n"
            + "if [ -n \"$CORR\" ]; then\n"
            + "  EXTRA_FORM=\"--form correspondent=$CORR\"\n"
            + "fi\n"
            + "curl -s --connect-timeout 10 --max-time 120 \"${CA_ARGS[@]}\" \\\n"
            + "  -H \"Authorization: Token $TOKEN\" \\\n"
            + "  -F \"document=@$FILE_PATH\" \\\n"
            + "  $EXTRA_FORM \\\n"
            + "  -D \"$HEADER_OUT\" \\\n"
            + "  \"$URL\" \\\n"
            + "  > \"$TEMP_OUT\" 2>/dev/null\n"
            + "CURL_EXIT=$?\n"
            + "HTTP_CODE=\"\"\n"
            + "if [ -s \"$HEADER_OUT\" ]; then\n"
            + "  read -r _ HTTP_CODE _ < \"$HEADER_OUT\"\n"
            + "  HTTP_CODE=$(echo \"$HTTP_CODE\" | tr -d '\\r\\n[:space:]')\n"
            + "fi\n"
            + "if [ \"$CURL_EXIT\" -eq 0 ] && [ -n \"$HTTP_CODE\" ] && [ \"$HTTP_CODE\" -ge 200 ] && [ \"$HTTP_CODE\" -lt 300 ]; then\n"
            + "  cat \"$TEMP_OUT\"\n"
            + "  exit 0\n"
            + "else\n"
            + "  echo \"HTTP Error: $HTTP_CODE (curl exit: $CURL_EXIT)\" >&2\n"
            + "  cat \"$TEMP_OUT\" >&2\n"
            + "  exit 3\n"
            + "fi"

    var url = root.paperlessUrl + "/api/documents/post_document/"
    var args = ["bash", "-c", cmd, "upload-script", filePath, String(correspondentId || ""), url]
    // $0=upload-script, $1=filePath, $2=correspondentId, $3=url

    var proc = apiProcComponent.createObject(root, {
      "command": args,
      "method": "POST"
    })

    proc.onSuccess = function(data) { root.onUploadSuccess(filePath, data) }
    proc.onFailure = function(err) { root.onUploadFailure(filePath, err) }

    proc.stdinEnabled = true
    proc.running = true
    proc.write(root.paperlessToken + "\n")
    proc.stdinEnabled = false
  }

  function onUploadSuccess(filePath, data) {
    var taskId = null
    if (data && typeof data === "string") {
      taskId = data.replace(/"/g, "").trim()
    } else if (data && typeof data === "object") {
      taskId = data.task_id || data.id || null
    }

    for (var i = 0; i < root.uploadQueue.length; i++) {
      if (root.uploadQueue[i].path === filePath) {
        root.uploadQueue[i].status = "submitted"
        root.uploadQueue[i].taskId = taskId
        break
      }
    }
    root.uploadQueue = root.uploadQueue.slice()

    if (taskId) {
      root.pollTaskStatus(filePath, taskId)
    }

    root.processUploadQueue()
  }

  function onUploadFailure(filePath, err) {
    for (var i = 0; i < root.uploadQueue.length; i++) {
      if (root.uploadQueue[i].path === filePath) {
        root.uploadQueue[i].status = "error"
        root.uploadQueue[i].error = err || "Upload failed"
        break
      }
    }
    root.uploadQueue = root.uploadQueue.slice()
    root.processUploadQueue()
  }

  // --- Task polling ---
  function pollTaskStatus(filePath, taskId) {
    if (!root.paperlessUrl || !root.paperlessToken) return

    var endpoint = "/api/tasks/?task_id=" + taskId
    root.apiRequest("GET", endpoint, null, function(data) {
      var tasks = null
      if (Array.isArray(data)) {
        tasks = data
      } else if (data && Array.isArray(data.results)) {
        tasks = data.results
      }

      if (!tasks || tasks.length === 0) {
        return
      }

      var task = tasks[0]
      var status = (task.status || "").toLowerCase()

      for (var i = 0; i < root.uploadQueue.length; i++) {
        if (root.uploadQueue[i].path === filePath) {
          if (status === "success") {
            root.uploadQueue[i].status = "completed"
            root.uploadQueue[i].relatedDocument = task.related_document_ids || null
            root.uploadQueue[i].result = task.result_data || ""
            root.uploadQueue = root.uploadQueue.slice()
            root.refresh()
          } else if (status === "failure" || status === "revoked") {
            root.uploadQueue[i].status = "error"
            root.uploadQueue[i].error = task.result_data || "Processing failed"
            root.uploadQueue = root.uploadQueue.slice()
          } else {
            setTimeout(function() { root.pollTaskStatus(filePath, taskId) }, 3000)
          }
          break
        }
      }
    })
  }

  function setTimeout(callback, delay) {
    var timer = timerComponent.createObject(root, { interval: delay })
    timer.triggered.connect(function() {
      timer.destroy()
      callback()
    })
    timer.start()
  }

  // --- Upload queue processing ---
  function processUploadQueue() {
    if (root.isUploading) return

    for (var i = 0; i < root.uploadQueue.length; i++) {
      if (root.uploadQueue[i].status === "waiting") {
        root.isUploading = true
        root.uploadQueue[i].status = "uploading"
        root.uploadQueue = root.uploadQueue.slice()
        root.uploadDocument(root.uploadQueue[i].path, root.uploadQueue[i].correspondentId)
        return
      }
    }

    root.isUploading = false
  }

  function addFilesToQueue(filePaths) {
    for (var i = 0; i < filePaths.length; i++) {
      var fp = filePaths[i].trim()
      if (fp === "") continue

      var ext = fp.split(".").pop().toLowerCase()
      var supported = false
      for (var j = 0; j < root.supportedFormats.length; j++) {
        if (ext === root.supportedFormats[j]) {
          supported = true
          break
        }
      }

      var fileName = fp.split("/").pop()

      root.uploadQueue.push({
        path: fp,
        name: fileName,
        status: supported ? "waiting" : "unsupported",
        error: supported ? "" : "Unsupported format: ." + ext,
        taskId: null,
        relatedDocument: null,
        result: ""
      })
    }
    root.uploadQueue = root.uploadQueue.slice()
    root.processUploadQueue()
  }

  // --- File picker via zenity ---
  function openFilePicker() {
    var cmd = "zenity --file-selection --multiple --title=\"Select documents for Paperless\" "
            + "--file-filter=\"PDF files | *.pdf\" "
            + "--file-filter=\"Image files | *.png *.jpg *.jpeg *.tiff *.tif\" "
            + "--file-filter=\"All files | *\" "
            + "--filename=$HOME/ 2>/dev/null || true"

    filePickerProc.command = ["bash", "-c", cmd]
    filePickerProc.running = true
  }

  // --- Correspondent creation with feedback ---
  function createCorrespondent(name) {
    root.corrFeedback = ""
    root.corrFeedbackIsError = false

    var data = {
      name: name,
      matching_algorithm: 6,
      is_insensitive: true
    }
    root.apiRequest("POST", "/api/correspondents/", data, function() {
      root.corrFeedback = "Created: " + name
      root.corrFeedbackIsError = false
      root.fetchCorrespondents()
      corrFeedbackTimer.restart()
    }, function(err) {
      root.corrFeedback = "Error: " + (err || "Failed to create")
      root.corrFeedbackIsError = true
      corrFeedbackTimer.restart()
    })
  }

  function fetchCorrespondents() {
    root.apiRequest("GET", "/api/correspondents/?page_size=1000", null, function(data) {
      if (data && Array.isArray(data.results)) {
        var validated = []
        var limit = Math.min(data.results.length, 1000)
        for (var i = 0; i < limit; i++) {
          var item = data.results[i]
          if (item && typeof item.id === 'number' && typeof item.name === 'string') {
            validated.push({
              id: item.id,
              name: item.name.substring(0, 256)
            })
          }
        }
        root.correspondents = validated
        root.rebuildCorrespondentOptions()
      }
    })
  }

  function fetchTags() {
    root.apiRequest("GET", "/api/tags/?page_size=1000", null, function(data) {
      if (data && Array.isArray(data.results)) {
        var validated = []
        var limit = Math.min(data.results.length, 1000)
        for (var i = 0; i < limit; i++) {
          var item = data.results[i]
          if (item && typeof item.id === 'number' && typeof item.name === 'string') {
            validated.push({
              id: item.id,
              name: item.name.substring(0, 256),
              color: typeof item.color === 'string' ? item.color.substring(0, 16) : "#444444",
              text_color: typeof item.text_color === 'string' ? item.text_color.substring(0, 16) : "#ffffff",
              is_inbox_tag: !!item.is_inbox_tag
            })
          }
        }
        root.tags = validated
        for (var j = 0; j < validated.length; j++) {
          if (validated[j].is_inbox_tag) {
            root.inboxTagId = validated[j].id
            break
          }
        }
      }
    })
  }

  function fetchInbox() {
    root.isFetching = true
    root.apiRequest("GET", "/api/documents/?is_in_inbox=true&limit=100", null, function(data) {
      root.isFetching = false
      if (data && Array.isArray(data.results)) {
        var validated = []
        var limit = Math.min(data.results.length, 100)
        for (var i = 0; i < limit; i++) {
          var item = data.results[i]
          if (item && typeof item.id === 'number' && typeof item.title === 'string') {
            var tagsArray = []
            if (Array.isArray(item.tags)) {
              var tagsLimit = Math.min(item.tags.length, 100)
              for (var t = 0; t < tagsLimit; t++) {
                if (typeof item.tags[t] === 'number') {
                  tagsArray.push(item.tags[t])
                }
              }
            }
            validated.push({
              id: item.id,
              title: item.title.substring(0, 512),
              correspondent: typeof item.correspondent === 'number' ? item.correspondent : null,
              created_date: typeof item.created_date === 'string' ? item.created_date.substring(0, 64) : "",
              created: typeof item.created === 'string' ? item.created.substring(0, 64) : "",
              tags: tagsArray
            })
          }
        }
        root.inboxDocuments = validated
        root.inboxCount = typeof data.count === 'number' ? data.count : validated.length
        root.downloadThumbnails(validated)
      }
    }, function() {
      root.isFetching = false
    })
  }

  function refresh() {
    if (root.paperlessUrl && root.paperlessToken) {
      root.fetchCorrespondents()
      root.fetchTags()
      root.fetchInbox()
    }
  }

  function downloadThumbnails(docs) {
    if (!docs || docs.length === 0) return
    if (!root.paperlessUrl || !root.paperlessToken) return
    if (!root.isUrlSecure(root.paperlessUrl)) {
      console.log("Error: Insecure paperless URL configured:", root.paperlessUrl)
      return
    }

    var base = root.paperlessUrl.trim()
    while (base.endsWith("/")) {
      base = base.substring(0, base.length - 1)
    }

    var cmd = "read -r TOKEN\n"
            + "PAPERLESS_URL=\"$1\"\n"
            + "shift\n"
            + "if [ -n \"$XDG_RUNTIME_DIR\" ]; then\n"
            + "  THUMB_DIR=\"$XDG_RUNTIME_DIR/omarchy/paperless_thumbs\"\n"
            + "else\n"
            + "  THUMB_DIR=\"$HOME/.cache/omarchy/paperless_thumbs\"\n"
            + "fi\n"
            + "mkdir -p -m 700 \"$THUMB_DIR\"\n"
            + "for id in \"$@\"; do\n"
            + "  DEST=\"$THUMB_DIR/${id}.png\"\n"
            + "  if [ -f \"$DEST\" ] && [ ! -L \"$DEST\" ]; then\n"
            + "    continue\n"
            + "  fi\n"
            + "  TEMP=$(mktemp \"$THUMB_DIR/thumb.XXXXXX\")\n"
            + "  chmod 600 \"$TEMP\"\n"
            + "  URL=\"${PAPERLESS_URL}/api/documents/${id}/thumb/\"\n"
            + "  if printf 'header = \"Authorization: Token %s\"\\nurl = \"%s\"\\n' \"$TOKEN\" \"$URL\" | curl -fsS --connect-timeout 5 --max-time 15 --config - | head -c 1048577 > \"$TEMP\"; then\n"
            + "    SIZE=$(stat -c %s \"$TEMP\")\n"
            + "    if [ \"$SIZE\" -le 1048576 ] && [ \"$SIZE\" -gt 0 ]; then\n"
            + "      chmod 600 \"$TEMP\"\n"
            + "      mv \"$TEMP\" \"$DEST\"\n"
            + "    else\n"
            + "      rm -f \"$TEMP\"\n"
            + "    fi\n"
            + "  else\n"
            + "    rm -f \"$TEMP\"\n"
            + "  fi\n"
            + "done"

    var args = ["bash", "-c", cmd, "download-script", base]
    for (var i = 0; i < docs.length; i++) {
      args.push(String(docs[i].id))
    }

    downloadThumbsProc.command = args
    downloadThumbsProc.stdinEnabled = true
    downloadThumbsProc.running = true
    downloadThumbsProc.write(root.paperlessToken + "\n")
    downloadThumbsProc.stdinEnabled = false
  }

  function updateDocumentTags(docId, nextTags) {
    var data = { tags: nextTags }
    root.patchDocument(docId, data)
  }

  function updateDocumentCorrespondent(docId, nextCorrId) {
    var data = { correspondent: nextCorrId }
    root.patchDocument(docId, data)
  }

  function patchDocument(docId, data) {
    console.log("PATCH document called:", docId, JSON.stringify(data))
    root.apiRequest("PATCH", "/api/documents/" + docId + "/", data, function() {
      root.refresh()
    })
  }

  function removeTagFromDocument(docId, tagId, currentTags) {
    console.log("Removing tag:", tagId, "from docId:", docId, "currentTags:", JSON.stringify(currentTags))
    var nextTags = []
    for (var i = 0; i < currentTags.length; i++) {
      if (currentTags[i] !== tagId) {
        nextTags.push(currentTags[i])
      }
    }
    root.updateDocumentTags(docId, nextTags)
  }

  function addTagToDocument(docId, tagId, currentTags) {
    console.log("addTagToDocument called - docId:", docId, "tagId:", tagId, "currentTags:", JSON.stringify(currentTags))
    if (currentTags.indexOf(tagId) !== -1) {
      console.log("Tag already exists on document")
      return
    }
    var nextTags = []
    for (var i = 0; i < currentTags.length; i++) {
      nextTags.push(currentTags[i])
    }
    nextTags.push(tagId)
    console.log("Calculated nextTags array:", JSON.stringify(nextTags))
    root.updateDocumentTags(docId, nextTags)
  }

  function markDocumentDone(docId, currentTags) {
    root.removeTagFromDocument(docId, root.inboxTagId, currentTags)
  }

  function deleteDocument(docId) {
    console.log("DELETE document called for docId:", docId)
    if (root.previewDocId === docId) {
      root.previewDocId = 0
    }
    root.apiRequest("DELETE", "/api/documents/" + docId + "/", null, function() {
      console.log("DELETE document success for docId:", docId)
      root.refresh()
    }, function(err) {
      console.log("DELETE document failed for docId:", docId, "error:", err)
    })
  }

  function saveConfiguration(url, token) {
    var cleanUrl = url.trim()
    while (cleanUrl.endsWith("/")) {
      cleanUrl = cleanUrl.substring(0, cleanUrl.length - 1)
    }

    if (!root.isUrlSecure(cleanUrl)) {
      console.log("Error: Invalid paperless URL protocol (must start with https:// or localhost-only http://)")
      return
    }

    var cfg = { url: cleanUrl, token: token.trim() }

    var cmd = "set -e\n"
            + "DIR=\"$HOME/.config/omarchy\"\n"
            + "mkdir -p \"$DIR\"\n"
            + "chmod 700 \"$DIR\"\n"
            + "TEMP_FILE=$(mktemp \"$DIR/paperless.json.XXXXXX\")\n"
            + "cat > \"$TEMP_FILE\"\n"
            + "chmod 600 \"$TEMP_FILE\"\n"
            + "mv \"$TEMP_FILE\" \"$DIR/paperless.json\""

    saveConfigProc.command = ["bash", "-c", cmd]
    saveConfigProc.stdinEnabled = true
    saveConfigProc.running = true
    saveConfigProc.write(JSON.stringify(cfg, null, 2))
    saveConfigProc.stdinEnabled = false
  }

  function loadConfiguration() {
    var cmd = "FILE=\"$HOME/.config/omarchy/paperless.json\"\n"
            + "if [ ! -e \"$FILE\" ]; then\n"
            + "  exit 0\n"
            + "fi\n"
            + "if [ -f \"$FILE\" ] && [ ! -L \"$FILE\" ] && [ \"$(stat -c '%u' \"$FILE\")\" = \"$(id -u)\" ]; then\n"
            + "  PERM=$(stat -c '%a' \"$FILE\")\n"
            + "  if [ \"$PERM\" = \"600\" ] || [ \"$PERM\" = \"400\" ]; then\n"
            + "    head -c 65536 \"$FILE\"\n"
            + "  else\n"
            + "    echo \"Error: insecure file permissions on paperless.json\" >&2\n"
            + "    exit 1\n"
            + "  fi\n"
            + "else\n"
            + "  echo \"Error: paperless.json is not a regular file, is a symlink, or has wrong owner\" >&2\n"
            + "  exit 1\n"
            + "fi"

    configProc.command = ["bash", "-c", cmd]
    configProc.running = true
  }

  // Theme values
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  Component.onCompleted: {
    root.loadConfiguration()
  }

  // --- Processes ---
  Process {
    id: configProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw) {
          try {
            var cfg = JSON.parse(raw)
            var urlStr = typeof cfg.url === "string" ? cfg.url.trim() : ""
            while (urlStr.endsWith("/")) {
              urlStr = urlStr.substring(0, urlStr.length - 1)
            }
            if (urlStr && root.isUrlSecure(urlStr)) {
              root.paperlessUrl = urlStr
              root.paperlessToken = typeof cfg.token === "string" ? cfg.token.trim() : ""
              root.refresh()
            } else {
              console.log("Error: Invalid or insecure paperless URL in configuration")
              root.paperlessUrl = ""
              root.paperlessToken = ""
            }
          } catch(e) {
            console.log("Error parsing paperless config:", e)
          }
        }
      }
    }
  }

  Process {
    id: downloadThumbsProc
    running: false
    stdinEnabled: true
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.thumbBuster++
      }
    }
  }

  Process {
    id: saveConfigProc
    running: false
    stdinEnabled: true
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.loadConfiguration()
      } else {
        console.log("Failed to save configuration")
      }
    }
  }

  Process {
    id: filePickerProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw) {
          var files = raw.split("\n")
          root.addFilesToQueue(files)
        }
      }
    }
  }

  Timer {
    id: corrFeedbackTimer
    interval: 4000
    running: false
    repeat: false
    onTriggered: {
      root.corrFeedback = ""
    }
  }

  Component {
    id: timerComponent
    Timer {
      running: false
      repeat: false
    }
  }

  Component {
    id: apiProcComponent
    Process {
      id: proc
      stdinEnabled: true
      property string method: ""
      property var onSuccess
      property var onFailure

      stdout: StdioCollector {
        id: apiStdout
        waitForEnd: true
      }

      stderr: StdioCollector {
        id: apiStderr
        waitForEnd: true
      }

      onExited: function(exitCode) {
        if (exitCode === 0) {
          var raw = String(apiStdout.text || "").trim()
          if (onSuccess) {
            try {
              var parsed = null
              if (raw !== "" && proc.method !== "DELETE") {
                try {
                  parsed = JSON.parse(raw)
                } catch (jsonErr) {
                  console.log("Failed to parse response JSON (length=" + raw.length + "):", jsonErr)
                  if (proc.method === "GET") {
                    throw jsonErr
                  }
                }
              }
              onSuccess(parsed)
            } catch (e) {
              console.log("Error processing success callback:", e)
              if (onFailure) onFailure("Parse Error")
            }
          }
        } else {
          var errText = String(apiStderr.text || "").trim()
          console.log("API Request failed with exit code:", exitCode, "error:", errText)
          if (onFailure) {
            if (exitCode === 2) {
              onFailure("Response too large")
            } else {
              onFailure("Status " + exitCode)
            }
          }
        }
        proc.destroy()
      }
    }
  }

  // --- UI ---
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.currentPanelWidth)
    contentHeight: panel.fittedContentHeight(root.paperlessUrl === "" || root.paperlessToken === "" ? setupColumn.implicitHeight : mainColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.someDropdownOpen || newCorrField.activeFocus || setupUrlField.activeFocus || setupTokenField.activeFocus
      onCloseRequested: root.close()

      // --- Setup Wizard ---
      Column {
        id: setupColumn
        visible: root.paperlessUrl === "" || root.paperlessToken === ""
        width: parent.width
        spacing: Style.space(14)

        Row {
          spacing: Style.space(10)
          Text {
            text: ""
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: 22
          }
          Text {
            text: "Paperless-ngx Setup"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
        }

        PanelSeparator { width: parent.width }

        Text {
          text: "Connect your status bar to your Paperless-ngx instance. Your credentials will be stored securely on your local machine."
          color: Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          width: parent.width
          wrapMode: Text.WordWrap
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          Text {
            text: "Server URL"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          TextField {
            id: setupUrlField
            width: parent.width
            placeholderText: "https://paperless.example.com"
            foreground: root.contentForeground
            accent: Color.accent
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          Text {
            text: "API Token"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          TextField {
            id: setupTokenField
            width: parent.width
            placeholderText: "Your API token..."
            foreground: root.contentForeground
            accent: Color.accent
            password: true
          }
        }

        Rectangle {
          width: parent.width
          height: Style.space(36)
          radius: Style.cornerRadius
          color: saveSetupMouse.containsMouse ? Color.accent : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

          Text {
            anchors.centerIn: parent
            text: "Save & Connect"
            color: saveSetupMouse.containsMouse ? "#ffffff" : root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          MouseArea {
            id: saveSetupMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (setupUrlField.text.trim() !== "" && setupTokenField.text.trim() !== "") {
                root.saveConfiguration(setupUrlField.text.trim(), setupTokenField.text.trim())
              }
            }
          }
        }
      }

      // --- Main Panel ---
      Row {
        id: panelRow
        visible: root.paperlessUrl !== "" && root.paperlessToken !== ""
        anchors.fill: parent
        spacing: Style.space(14)

        // Large Preview Panel
        BorderSurface {
          id: largePreview
          width: root.previewDocId !== 0 ? (largeImage.status === Image.Ready ? Math.min(Style.space(400), (largePreview.height - Style.space(24)) * (largeImage.implicitWidth / largeImage.implicitHeight) + Style.space(24)) : Style.space(250)) : 0
          height: parent.height
          clip: true
          visible: width > 0
          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.02)
          radius: Style.cornerRadius
          borderSpec: Border.flat(Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08), 1)

          Behavior on width {
            NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
          }

          Item {
            anchors.fill: parent
            anchors.margins: Style.space(12)

            Image {
              id: largeImage
              anchors.fill: parent
              source: root.previewDocId !== 0 ? ("file://" + root.thumbDir + "/" + root.previewDocId + ".png?v=" + root.thumbBuster) : ""
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
            }

            Rectangle {
              id: zoomLens
              x: Math.max(0, Math.min(previewMouseArea.width - width, previewMouseArea.mouseX - width / 2))
              y: Math.max(0, Math.min(previewMouseArea.height - height, previewMouseArea.mouseY - height / 2))
              width: Style.space(200)
              height: Style.space(200)
              radius: width / 2
              color: "#1a1a1a"
              border.color: Color.accent
              border.width: Style.space(3)
              clip: true
              visible: previewMouseArea.containsMouse && root.previewDocId !== 0
              enabled: false

              property real scaleFactor: 2.2

              Image {
                id: zoomImage
                source: root.previewDocId !== 0 ? ("file://" + root.thumbDir + "/" + root.previewDocId + ".png?v=" + root.thumbBuster) : ""
                fillMode: Image.PreserveAspectFit
                smooth: true
                asynchronous: true
                width: largeImage.width * zoomLens.scaleFactor
                height: largeImage.height * zoomLens.scaleFactor
                x: zoomLens.width / 2 - previewMouseArea.mouseX * zoomLens.scaleFactor
                y: zoomLens.height / 2 - previewMouseArea.mouseY * zoomLens.scaleFactor
              }
            }

            MouseArea {
              id: previewMouseArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.previewDocId = 0
              }
            }
          }
        }

        // --- Main Column ---
        Column {
          id: mainColumn
          width: parent.width - largePreview.width - (largePreview.visible ? panelRow.spacing : 0)
          spacing: Style.space(10)

          // Title bar
          Item {
            width: parent.width
            height: titleRow.height

            Row {
              id: titleRow
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Text {
                text: ""
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 22
              }

              Text {
                text: "Paperless Inbox"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }

            PanelActionButton {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑐"
              tooltipText: "Refresh Inbox"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.refresh()
            }
          }

          PanelSeparator { width: parent.width }

          // --- Upload section ---
          Rectangle {
            width: parent.width
            height: uploadColumn.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.03)
            border.width: 1
            border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

            Column {
              id: uploadColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(6)

              // Add documents button
              Rectangle {
                width: parent.width
                height: Style.space(32)
                radius: Style.cornerRadius
                color: addDocMouse.containsMouse ? Color.accent : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

                Text {
                  anchors.centerIn: parent
                  text: "+ Add documents"
                  color: addDocMouse.containsMouse ? "#ffffff" : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                MouseArea {
                  id: addDocMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openFilePicker()
                }
              }

              // Upload queue
              Repeater {
                model: root.uploadQueue

                delegate: Row {
                  required property var modelData
                  width: uploadColumn.width
                  spacing: Style.space(6)

                  Text {
                    text: {
                      var s = modelData.status
                      if (s === "waiting") return "⏳"
                      if (s === "uploading") return "⬆"
                      if (s === "submitted") return "⏳"
                      if (s === "completed") return "✓"
                      if (s === "error") return "✗"
                      if (s === "unsupported") return "⚠"
                      return "•"
                    }
                    color: {
                      var s = modelData.status
                      if (s === "completed") return "#4caf50"
                      if (s === "error" || s === "unsupported") return Color.urgent
                      return root.contentForeground
                    }
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    width: Style.space(16)
                  }

                  Text {
                    text: modelData.name
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    width: parent.width - Style.space(80)
                    elide: Text.ElideRight
                  }

                  Text {
                    text: {
                      var s = modelData.status
                      if (s === "waiting") return "Waiting"
                      if (s === "uploading") return "Uploading..."
                      if (s === "submitted") return "Processing..."
                      if (s === "completed") return "Done"
                      if (s === "error") return modelData.error || "Error"
                      if (s === "unsupported") return "Unsupported"
                      return s
                    }
                    color: {
                      var s = modelData.status
                      if (s === "completed") return "#4caf50"
                      if (s === "error" || s === "unsupported") return Color.urgent
                      return Qt.darker(root.contentForeground, 1.3)
                    }
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    width: Style.space(64)
                    horizontalAlignment: Text.AlignRight
                  }
                }
              }

              // Clear completed button
              Rectangle {
                width: parent.width
                height: Style.space(24)
                radius: Style.space(4)
                visible: {
                  for (var i = 0; i < root.uploadQueue.length; i++) {
                    if (root.uploadQueue[i].status === "completed" || root.uploadQueue[i].status === "error" || root.uploadQueue[i].status === "unsupported")
                      return true
                  }
                  return false
                }
                color: clearQueueMouse.containsMouse ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.15) : "transparent"

                Text {
                  anchors.centerIn: parent
                  text: "Clear completed"
                  color: Qt.darker(root.contentForeground, 1.3)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: clearQueueMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var cleaned = []
                    for (var i = 0; i < root.uploadQueue.length; i++) {
                      if (root.uploadQueue[i].status === "waiting" || root.uploadQueue[i].status === "uploading" || root.uploadQueue[i].status === "submitted")
                        cleaned.push(root.uploadQueue[i])
                    }
                    root.uploadQueue = cleaned
                  }
                }
              }
            }
          }

          // --- Correspondent quick-add ---
          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: newCorrField
              width: parent.width - Style.space(110)
              placeholderText: "New correspondent name..."
              foreground: root.contentForeground
              accent: Color.accent

              onAccepted: {
                if (text.trim() !== "") {
                  root.createCorrespondent(text.trim())
                  text = ""
                }
              }
            }

            Rectangle {
              width: Style.space(100)
              height: Style.spacing.controlHeight || Style.space(30)
              radius: Style.cornerRadius
              color: addCorrMouse.containsMouse ? Color.accent : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

              Text {
                anchors.centerIn: parent
                text: "+ Add Corr"
                color: addCorrMouse.containsMouse ? "#ffffff" : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                id: addCorrMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (newCorrField.text.trim() !== "") {
                    root.createCorrespondent(newCorrField.text.trim())
                    newCorrField.text = ""
                  }
                }
              }
            }
          }

          // Correspondent feedback
          Text {
            visible: root.corrFeedback !== ""
            text: root.corrFeedback
            color: root.corrFeedbackIsError ? Color.urgent : "#4caf50"
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }

          PanelSeparator { width: parent.width }

          // Empty state
          Text {
            visible: root.inboxDocuments.length === 0 && !root.isFetching
            text: "Inbox is empty! 󰄬"
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
            topPadding: Style.space(24)
            bottomPadding: Style.space(24)
          }

          // Loading state
          Text {
            visible: root.inboxDocuments.length === 0 && root.isFetching
            text: "Loading inbox..."
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
            topPadding: Style.space(24)
            bottomPadding: Style.space(24)
          }

          // Document list
          Flickable {
            visible: root.inboxDocuments.length > 0
            width: parent.width
            height: root.previewDocId !== 0 ? Style.space(420) : Math.min(Style.space(480), documentsColumn.implicitHeight)
            contentWidth: width
            contentHeight: documentsColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            Column {
              id: documentsColumn
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: root.inboxDocuments

                delegate: BorderSurface {
                  id: cardDelegate
                  required property var modelData
                  readonly property var docObj: modelData

                  width: parent.width
                  implicitHeight: Math.max(Style.space(127), docColumn.implicitHeight) + Style.space(16)
                  color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.03)
                  radius: Style.cornerRadius
                  borderSpec: Border.flat(Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08), 1)

                  Item {
                    id: thumbnail
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.margins: Style.space(8)
                    width: Style.space(90)
                    height: Style.space(127)

                    Rectangle {
                      anchors.fill: parent
                      radius: Style.cornerRadius
                      color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)
                      border.width: 1
                      border.color: root.previewDocId === docObj.id ? Color.accent : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.1)
                      clip: true

                      Image {
                        id: thumbImage
                        anchors.fill: parent
                        source: "file://" + root.thumbDir + "/" + docObj.id + ".png?v=" + root.thumbBuster
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                        opacity: imgMouse.containsMouse ? 0.85 : 1.0

                        scale: imgMouse.containsMouse ? 1.04 : 1.0
                        Behavior on scale { NumberAnimation { duration: 120 } }
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                      }

                      Rectangle {
                        visible: imgMouse.containsMouse
                        anchors.fill: parent
                        color: Qt.rgba(0, 0, 0, 0.2)

                        Text {
                          anchors.centerIn: parent
                          text: root.previewDocId === docObj.id ? "󰍊" : "󰍉"
                          color: "#ffffff"
                          font.family: root.contentFontFamily
                          font.pixelSize: 24
                        }
                      }
                    }

                    MouseArea {
                      id: imgMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        if (root.previewDocId === docObj.id) {
                          root.previewDocId = 0
                        } else {
                          root.previewDocId = docObj.id
                        }
                      }
                    }

                    PanelToolTip {
                      visible: imgMouse.containsMouse
                      text: root.previewDocId === docObj.id ? "Click to close preview" : "Click to preview document inline"
                      fontFamily: root.contentFontFamily
                    }
                  }

                  Column {
                    id: actionCol
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(8)
                    width: Style.space(90)
                    spacing: Style.space(6)

                    Rectangle {
                      width: Style.space(90)
                      height: Style.space(28)
                      radius: Style.space(4)
                      color: doneMouse.containsMouse ? Color.accent : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

                      Text {
                        anchors.centerIn: parent
                        text: "󰄬 Done"
                        color: doneMouse.containsMouse ? "#ffffff" : root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      MouseArea {
                        id: doneMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.markDocumentDone(docObj.id, docObj.tags)
                        }
                      }
                    }

                    Rectangle {
                      width: Style.space(90)
                      height: Style.space(28)
                      radius: Style.space(4)
                      color: deleteMouse.containsMouse ? Color.urgent : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

                      Text {
                        anchors.centerIn: parent
                        text: "󰆴 Delete"
                        color: deleteMouse.containsMouse ? "#ffffff" : root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      MouseArea {
                        id: deleteMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.deleteDocument(docObj.id)
                        }
                      }
                    }
                  }

                  Column {
                    id: docColumn
                    anchors.left: thumbnail.right
                    anchors.right: actionCol.left
                    anchors.top: parent.top
                    anchors.leftMargin: Style.space(14)
                    anchors.rightMargin: Style.space(14)
                    anchors.topMargin: Style.space(8)
                    spacing: Style.space(8)

                    Text {
                      text: docObj.title
                      textFormat: Text.PlainText
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      width: parent.width
                      elide: Text.ElideRight
                    }

                    Row {
                      width: parent.width
                      spacing: Style.space(14)

                      Column {
                        width: parent.width * 0.5 - Style.space(7)
                        spacing: Style.space(4)

                        Text {
                          text: "Correspondent"
                          color: Qt.darker(root.contentForeground, 1.4)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }

                        SearchableDropdown {
                          id: corrDropdown
                          width: parent.width
                          showLabel: false
                          fontFamily: root.contentFontFamily
                          placeholderText: "None"
                          options: root.correspondentOptions
                          value: docObj.correspondent !== null ? String(docObj.correspondent) : ""
                          onPopupOpenChanged: root.registerDropdownOpen(this, popupOpen)
                          onChanged: {
                            root.updateDocumentCorrespondent(docObj.id, value === "" ? null : parseInt(value, 10))
                          }
                        }
                      }

                      Column {
                        width: parent.width * 0.5 - Style.space(7)
                        spacing: Style.space(4)

                        Text {
                          text: "Created Date"
                          color: Qt.darker(root.contentForeground, 1.4)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }

                        Text {
                          text: docObj.created_date || docObj.created || "Unknown"
                          textFormat: Text.PlainText
                          color: root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.body
                          height: Style.spacing.controlHeight
                          verticalAlignment: Text.AlignVCenter
                        }
                      }
                    }

                    Column {
                      width: parent.width
                      spacing: Style.space(4)

                      Text {
                        text: "Tags"
                        color: Qt.darker(root.contentForeground, 1.4)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      Flow {
                        width: parent.width
                        spacing: Style.space(6)

                        Repeater {
                          model: docObj.tags

                          delegate: Rectangle {
                            required property int modelData
                            property var tagObj: root.getTagObj(modelData)
                            visible: tagObj !== null
                            width: visible ? rowFlow.implicitWidth + Style.space(16) : 0
                            height: Style.space(24)
                            radius: Style.space(4)
                            color: tagObj ? tagObj.color : "#444444"

                            Row {
                              id: rowFlow
                              anchors.centerIn: parent
                              spacing: Style.space(6)

                              Text {
                                text: tagObj ? tagObj.name : ""
                                textFormat: Text.PlainText
                                color: tagObj ? tagObj.text_color : "#ffffff"
                                font.family: root.contentFontFamily
                                font.pixelSize: Style.font.caption
                                font.bold: true
                              }

                              Text {
                                text: "󰅖"
                                color: tagObj ? tagObj.text_color : "#ffffff"
                                opacity: tagMouse.containsMouse ? 1.0 : 0.6
                                font.family: root.contentFontFamily
                                font.pixelSize: Style.font.caption

                                MouseArea {
                                  id: tagMouse
                                  anchors.fill: parent
                                  hoverEnabled: true
                                  cursorShape: Qt.PointingHandCursor
                                  onClicked: {
                                    root.removeTagFromDocument(docObj.id, modelData, docObj.tags)
                                  }
                                }
                              }
                            }
                          }
                        }

                        Dropdown {
                          id: addTagDropdown
                          width: Style.space(120)
                          height: Style.space(24)
                          fontFamily: root.contentFontFamily
                          showLabel: false
                          options: root.getTagOptionsForDoc(docObj.tags)
                          value: "+ Add Tag"
                          onPopupOpenChanged: root.registerDropdownOpen(this, popupOpen)
                          onChanged: {
                            if (value && value !== "+ Add Tag") {
                              root.addTagToDocument(docObj.id, parseInt(value, 10), docObj.tags)
                            }
                            addTagDropdown.value = "+ Add Tag"
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
