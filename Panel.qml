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

  // Smoothly animated panel width
  readonly property real targetWidth: Style.space(720) + (previewDocId !== 0 ? largePreview.width + Style.space(14) : 0)
  property real currentPanelWidth: Style.space(720)

  Behavior on currentPanelWidth {
    NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
  }

  onTargetWidthChanged: currentPanelWidth = targetWidth

  property var openDropdownsList: []
  readonly property bool someDropdownOpen: openDropdownsList.length > 0

  onOpenedChanged: {
    if (opened) {
      root.refresh()
    } else {
      root.previewDocId = 0 // Reset preview when closed
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

  function refresh() {
    if (root.paperlessUrl && root.paperlessToken) {
      root.isFetching = true
      fetchInboxProc.running = true
    }
  }

  function downloadThumbnails(docs) {
    if (!docs || docs.length === 0) return
    var cmd = "mkdir -p /tmp/paperless_thumbs && "
    for (var i = 0; i < docs.length; i++) {
      var id = docs[i].id
      var url = root.paperlessUrl + "/api/documents/" + id + "/thumb/"
      var dest = "/tmp/paperless_thumbs/" + id + ".png"
      cmd += "if [ ! -f " + dest + " ]; then curl -fsS -H 'Authorization: Token " + root.paperlessToken + "' '" + url + "' -o " + dest + " & fi; "
    }
    cmd += "wait"

    downloadThumbsProc.command = ["bash", "-c", cmd]
    downloadThumbsProc.running = true
  }



  function updateDocumentTags(docId, nextTags) {
    var data = { tags: nextTags }
    patchDocument(docId, data)
  }

  function updateDocumentCorrespondent(docId, nextCorrId) {
    var data = { correspondent: nextCorrId }
    patchDocument(docId, data)
  }

  function patchDocument(docId, data) {
    console.log("PATCH document called:", docId, JSON.stringify(data))
    patchDocProc.command = [
      "curl", "-fsS", "-X", "PATCH",
      "-H", "Authorization: Token " + root.paperlessToken,
      "-H", "Content-Type: application/json",
      "-d", JSON.stringify(data),
      root.paperlessUrl + "/api/documents/" + docId + "/"
    ]
    patchDocProc.running = true
  }

  function removeTagFromDocument(docId, tagId, currentTags) {
    console.log("Removing tag:", tagId, "from docId:", docId, "currentTags:", JSON.stringify(currentTags))
    var nextTags = []
    for (var i = 0; i < currentTags.length; i++) {
      if (currentTags[i] !== tagId) {
        nextTags.push(currentTags[i])
      }
    }
    updateDocumentTags(docId, nextTags)
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
    updateDocumentTags(docId, nextTags)
  }

  function markDocumentDone(docId, currentTags) {
    removeTagFromDocument(docId, root.inboxTagId, currentTags)
  }

  function deleteDocument(docId) {
    if (root.previewDocId == docId) {
      root.previewDocId = 0
    }
    deleteDocProc.command = [
      "curl", "-fsS", "-X", "DELETE",
      "-H", "Authorization: Token " + root.paperlessToken,
      root.paperlessUrl + "/api/documents/" + docId + "/"
    ]
    deleteDocProc.running = true
  }

  function createCorrespondent(name) {
    var data = {
      name: name,
      matching_algorithm: 6,
      is_insensitive: true
    }
    createCorrProc.command = [
      "curl", "-fsS", "-X", "POST",
      "-H", "Authorization: Token " + root.paperlessToken,
      "-H", "Content-Type: application/json",
      "-d", JSON.stringify(data),
      root.paperlessUrl + "/api/correspondents/"
    ]
    createCorrProc.running = true
  }

  // Setup Wizard configuration writer (no sensitive data hardcoded)
  function saveConfiguration(url, token) {
    var cfg = { url: url, token: token }
    var cmd = "mkdir -p ~/.config/omarchy && cat << 'EOF' > ~/.config/omarchy/paperless.json\n"
            + JSON.stringify(cfg, null, 2)
            + "\nEOF\nchmod 600 ~/.config/omarchy/paperless.json"

    saveConfigProc.command = ["bash", "-c", cmd]
    saveConfigProc.running = true
  }

  // Theme values
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  Component.onCompleted: {
    configProc.running = true
  }

  Process {
    id: configProc
    running: false
    command: ["cat", "/home/sebastian/.config/omarchy/paperless.json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw) {
          try {
            var cfg = JSON.parse(raw)
            root.paperlessUrl = cfg.url
            root.paperlessToken = cfg.token
            fetchCorrespondentsProc.running = true
            fetchTagsProc.running = true
            root.refresh()
          } catch(e) {
            console.log("Error parsing paperless config:", e)
          }
        }
      }
    }
  }

  Process {
    id: fetchCorrespondentsProc
    running: false
    command: ["curl", "-fsS", "-H", "Authorization: Token " + root.paperlessToken, root.paperlessUrl + "/api/correspondents/?page_size=1000"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw) {
          try {
            var data = JSON.parse(raw)
            if (data && data.results) {
              root.correspondents = data.results
              root.rebuildCorrespondentOptions()
            }
          } catch(e) {
            console.log("Error parsing correspondents:", e)
          }
        }
      }
    }
  }

  Process {
    id: fetchTagsProc
    running: false
    command: ["curl", "-fsS", "-H", "Authorization: Token " + root.paperlessToken, root.paperlessUrl + "/api/tags/?page_size=1000"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw) {
          try {
            var data = JSON.parse(raw)
            if (data && data.results) {
              root.tags = data.results
              for (var i = 0; i < data.results.length; i++) {
                if (data.results[i].is_inbox_tag) {
                  root.inboxTagId = data.results[i].id
                  break
                }
              }
            }
          } catch(e) {
            console.log("Error parsing tags:", e)
          }
        }
      }
    }
  }

  Process {
    id: fetchInboxProc
    running: false
    command: ["curl", "-fsS", "-H", "Authorization: Token " + root.paperlessToken, root.paperlessUrl + "/api/documents/?is_in_inbox=true&limit=100"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.isFetching = false
        var raw = String(text || "").trim()
        if (raw) {
          try {
            var data = JSON.parse(raw)
            if (data && data.results) {
              root.inboxDocuments = data.results
              root.inboxCount = data.count !== undefined ? data.count : data.results.length
              root.downloadThumbnails(data.results)
            }
          } catch(e) {
            console.log("Error parsing inbox documents:", e)
          }
        }
      }
    }
    onExited: {
      root.isFetching = false
    }
  }

  Process {
    id: downloadThumbsProc
    running: false
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.thumbBuster++
      }
    }
  }



  Process {
    id: patchDocProc
    running: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: console.log("PATCH API Error details:", text) }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.refresh()
      } else {
        console.log("PATCH API failed with exit code:", exitCode)
      }
    }
  }

  Process {
    id: deleteDocProc
    running: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: console.log("DELETE API Error details:", text) }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.refresh()
      } else {
        console.log("DELETE API failed with exit code:", exitCode)
      }
    }
  }

  Process {
    id: createCorrProc
    running: false
    onExited: function(exitCode) {
      if (exitCode === 0) {
        fetchCorrespondentsProc.running = true
      }
    }
  }

  Process {
    id: saveConfigProc
    running: false
    onExited: function(exitCode) {
      if (exitCode === 0) {
        configProc.running = true
      }
    }
  }

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

      // Dynamic Setup Wizard Layout
      Column {
        id: setupColumn
        visible: root.paperlessUrl === "" || root.paperlessToken === ""
        width: parent.width
        spacing: Style.space(14)

        Row {
          spacing: Style.space(10)
          Text {
            text: ""
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

        PanelSeparator {
          width: parent.width
        }

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

      // Sliding Panel & Document List Row
      Row {
        id: panelRow
        visible: root.paperlessUrl !== "" && root.paperlessToken !== ""
        anchors.fill: parent
        spacing: Style.space(14)

        // Large Preview Panel (on the left)
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
              source: root.previewDocId !== 0 ? ("file:///tmp/paperless_thumbs/" + root.previewDocId + ".png?v=" + root.thumbBuster) : ""
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
            }

            // Beautiful Magnifier/Zoom Lens
            Rectangle {
              id: zoomLens
              // Lens stays centered on mouse but clamped within the previewMouseArea bounds
              x: Math.max(0, Math.min(previewMouseArea.width - width, previewMouseArea.mouseX - width / 2))
              y: Math.max(0, Math.min(previewMouseArea.height - height, previewMouseArea.mouseY - height / 2))
              width: Style.space(200)
              height: Style.space(200)
              radius: width / 2
              color: "#1a1a1a" // Dark fallback background for high contrast
              border.color: Color.accent
              border.width: Style.space(3)
              clip: true
              visible: previewMouseArea.containsMouse && root.previewDocId !== 0
              enabled: false // Transparent to hover/mouse events

              // Magnification factor
              property real scaleFactor: 2.2

              Image {
                id: zoomImage
                source: "file:///tmp/paperless_thumbs/" + root.previewDocId + ".png?v=" + root.thumbBuster
                fillMode: Image.PreserveAspectFit
                smooth: true
                asynchronous: true
                width: largeImage.width * zoomLens.scaleFactor
                height: largeImage.height * zoomLens.scaleFactor

                // Position the magnified source relative to the lens so that the point under the mouse is centered
                x: zoomLens.width / 2 - previewMouseArea.mouseX * zoomLens.scaleFactor
                y: zoomLens.height / 2 - previewMouseArea.mouseY * zoomLens.scaleFactor
              }
            }

            // Click image to close/shrink (placed on top of zoomLens so zoomLens never intercepts events)
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

        // Main List Column (on the right)
        Column {
          id: mainColumn
          width: parent.width - largePreview.width - (largePreview.visible ? panelRow.spacing : 0)
          spacing: Style.space(14)

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
                text: ""
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

          PanelSeparator {
            width: parent.width
          }

          // Quick Add Correspondent Row
          Row {
            width: parent.width
            spacing: Style.space(10)

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

          PanelSeparator {
            width: parent.width
          }

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

          // Loading state when empty
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

          // Scrollable document list
          Flickable {
            visible: root.inboxDocuments.length > 0
            width: parent.width
            height: root.previewDocId !== 0 ? Style.space(520) : Math.min(Style.space(480), documentsColumn.implicitHeight)
            contentWidth: width
            contentHeight: documentsColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            Column {
              id: documentsColumn
              width: parent.width
              spacing: Style.space(12)

              Repeater {
                model: root.inboxDocuments

                delegate: BorderSurface {
                  id: cardDelegate
                  required property var modelData // this is the document
                  readonly property var docObj: modelData // alias to prevent name shadowing from nested repeaters

                  width: parent.width
                  implicitHeight: Math.max(Style.space(127), docColumn.implicitHeight) + Style.space(16)
                  color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.03)
                  radius: Style.cornerRadius
                  borderSpec: Border.flat(Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08), 1)

                  // Document thumbnail on the left (clickable to preview inline)
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
                        source: "file:///tmp/paperless_thumbs/" + docObj.id + ".png?v=" + root.thumbBuster
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                        opacity: imgMouse.containsMouse ? 0.85 : 1.0

                        scale: imgMouse.containsMouse ? 1.04 : 1.0
                        Behavior on scale { NumberAnimation { duration: 120 } }
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                      }

                      // Magnifying glass overlay on hover
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

                  // Done / Delete action column on the right
                  Column {
                    id: actionCol
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(8)
                    width: Style.space(90)
                    spacing: Style.space(6)

                    // Done button
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

                    // Delete button
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

                  // Document details in the middle (auto-stretched)
                  Column {
                    id: docColumn
                    anchors.left: thumbnail.right
                    anchors.right: actionCol.left
                    anchors.top: parent.top
                    anchors.leftMargin: Style.space(14)
                    anchors.rightMargin: Style.space(14)
                    anchors.topMargin: Style.space(8)
                    spacing: Style.space(10)

                    Text {
                      text: docObj.title
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      width: parent.width
                      elide: Text.ElideRight
                    }

                    // Correspondent and date row
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
                          color: root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.body
                          height: Style.spacing.controlHeight
                          verticalAlignment: Text.AlignVCenter
                        }
                      }
                    }

                    // Tags section
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
                            required property int modelData // this is the tag ID
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
